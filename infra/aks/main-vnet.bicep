// Enhanced Bicep template with VNet integration for AKS and Cosmos DB
// Secure design: AKS and Cosmos DB in the same VNet with controlled public exposure

@description('Azure region for all resources')
param location string

@description('Name of the AKS cluster')
param aksClusterName string

@description('Name of Azure Container Registry')
param acrName string

@description('Name of Cosmos DB account')
param cosmosDbAccountName string

@description('Name of Cosmos DB database')
param cosmosDbDatabaseName string

@description('Name of Cosmos DB container')
param cosmosDbContainerName string

@description('Name of managed identity')
param managedIdentityName string

@description('SSH public key for AKS Linux nodes')
param sshPublicKey string

@description('Name of the Virtual Network')
param vnetName string = 'aks-cosmos-vnet'

@description('Address prefix for the Virtual Network')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Address prefix for the AKS subnet')
param aksSubnetAddressPrefix string = '10.0.0.0/24'

@description('Address prefix for the AKS pod subnet')
param aksPodSubnetAddressPrefix string = '10.0.1.0/24'

@description('Address prefix for the Azure services subnet')
param servicesSubnetAddressPrefix string = '10.0.2.0/24'

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: aksSubnetAddressPrefix
          // Service endpoints for AKS subnet
          serviceEndpoints: [
            {
              service: 'Microsoft.AzureCosmosDB'
            }
            {
              service: 'Microsoft.ContainerRegistry'
            }
          ]
        }
      }
      {
        name: 'pod-subnet'
        properties: {
          addressPrefix: aksPodSubnetAddressPrefix
          // Enable delegation for pod subnet for CNI overlay
          delegations: [
            {
              name: 'aks-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerService/managedClusters'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.AzureCosmosDB'
            }
          ]
        }
      }
      {
        name: 'services-subnet'
        properties: {
          addressPrefix: servicesSubnetAddressPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.AzureCosmosDB'
            }
          ]
        }
      }
    ]
  }
}

// Get references to subnets
resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: '${vnetName}/aks-subnet'
  dependsOn: [
    vnet
  ]
}

resource podSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: '${vnetName}/pod-subnet' 
  dependsOn: [
    vnet
  ]
}

resource servicesSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: '${vnetName}/services-subnet'
  dependsOn: [
    vnet
  ]
}

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
    // Improved network security: link to VNet
    networkRuleSet: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: aksSubnet.id
          action: 'Allow'
        }
      ]
    }
    publicNetworkAccess: 'Enabled' // Can be changed to disabled after setup
  }
}

// User Assigned Managed Identity
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

// Cosmos DB Account with VNet integration
resource cosmosdb 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: cosmosDbAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    enableFreeTier: false
    // Configure network access with VNet integration
    publicNetworkAccess: 'Enabled'
    networkAclBypass: 'AzureServices'
    // Use service endpoints to restrict access to Cosmos DB
    isVirtualNetworkFilterEnabled: true
    virtualNetworkRules: [
      {
        id: aksSubnet.id
      }
      {
        id: podSubnet.id
      }
      {
        id: servicesSubnet.id
      }
    ]
    enableAutomaticFailover: false
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

// Cosmos DB SQL Database
resource cosmosdbDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-04-15' = {
  parent: cosmosdb
  name: cosmosDbDatabaseName
  properties: {
    resource: {
      id: cosmosDbDatabaseName
    }
  }
}

// Cosmos DB SQL Container
resource cosmosdbContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosdbDatabase
  name: cosmosDbContainerName
  properties: {
    resource: {
      id: cosmosDbContainerName
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
    }
  }
}

// Assign Cosmos DB Data Contributor role to Managed Identity
resource cosmosDbContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uami.id, cosmosdb.id, 'cosmosDbContributor')
  scope: cosmosdb
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Cosmos DB Data Contributor
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    uami
  ]
}

// Set up Cosmos DB SQL Role Assignment for the managed identity
resource cosmosdbSqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  parent: cosmosdb
  name: guid(cosmosdb.id, uami.id, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: '${cosmosdb.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002' // Built-in Data Contributor role
    principalId: uami.properties.principalId
    scope: cosmosdb.id
  }
  dependsOn: [
    uami
  ]
}

// AKS Cluster with VNet integration and Azure CNI overlay networking
resource aks 'Microsoft.ContainerService/managedClusters@2023-04-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${aksClusterName}-dns'
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: 2
        vmSize: 'Standard_DS2_v2'
        osType: 'Linux'
        mode: 'System'
        vnetSubnetID: aksSubnet.id // Connect to VNet subnet
      }
    ]
    enableRBAC: true
    // Enable Workload Identity
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    // Use Azure CNI overlay networking
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'azure'
      loadBalancerSku: 'standard'
      podCidr: aksPodSubnetAddressPrefix
      serviceCidr: '10.0.3.0/24'
      dnsServiceIP: '10.0.3.10'
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
      }
    }
    servicePrincipalProfile: {
      clientId: 'msi'
    }
    linuxProfile: {
      adminUsername: 'azureuser'      ssh: {
        publicKeys: [
          {
            keyData: sshPublicKey
          }
        ]
      }
    }
  }
  dependsOn: [
    vnet
    acr
  ]
}

// Grant AKS access to pull from ACR
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, aks.id, acr.id, 'acrPullRole')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull role
    principalId: aks.identity.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    aks
  ]
}

// Create a federated identity credential for the backend application
resource federatedIdentityCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'backend-federated-identity'
  parent: uami
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:eventapp:backend-sa'
  }
  dependsOn: [
    aks
  ]
}

output aksName string = aks.name
output acrName string = acr.name
output cosmosDbAccountName string = cosmosdb.name
output cosmosDbEndpoint string = cosmosdb.properties.documentEndpoint
output managedIdentityResourceId string = uami.id
output managedIdentityClientId string = uami.properties.clientId
output managedIdentityPrincipalId string = uami.properties.principalId
output vnetId string = vnet.id
output aksSubnetId string = aksSubnet.id
output aksOidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
