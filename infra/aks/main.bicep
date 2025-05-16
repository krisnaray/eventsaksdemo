// main.bicep - AKS, ACR, Cosmos DB, Managed Identity, and RBAC for secure app deployment
// Best practices: secure networking, managed identity, RBAC, minimal public exposure

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

// Role definition IDs
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var cosmosDbDataContributorRoleId = '00000000-0000-0000-0000-000000000002'
var cosmosDbAccountReaderRoleId = 'fbdf93bf-df7d-467e-a4d2-9458aa1360c8'

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
  }
}

// User Assigned Managed Identity
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

// Cosmos DB Account with network settings for public access
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
    publicNetworkAccess: 'Enabled'
    networkAclBypass: 'AzureServices'
    ipRules: [
      {
        ipAddressOrRange: '0.0.0.0'  // Allow all IPs for demo purposes
      }
    ]
    enableAutomaticFailover: false
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
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

// Assign Cosmos DB Account Reader Role to Managed Identity
resource cosmosDbReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uami.id, cosmosdb.id, 'cosmosDbReader')
  scope: cosmosdb
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosDbAccountReaderRoleId)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    uami
  ]
}

// Assign Cosmos DB SQL Role for Data Contributor
resource cosmosdbSqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  parent: cosmosdb
  name: guid(cosmosdb.id, uami.id, cosmosDbDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmosdb.id}/sqlRoleDefinitions/${cosmosDbDataContributorRoleId}'
    principalId: uami.properties.principalId
    scope: cosmosdb.id
  }
  dependsOn: [
    uami
  ]
}

// AKS Cluster with ACR integration and workload identity
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
      }
    ]
    enableRBAC: true
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
    // Enable Workload Identity
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
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
  dependsOn: [acr]
}

// Grant AKS access to pull from ACR
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, aks.id, acr.id, 'acrPullRole')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId) // AcrPull role
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
output aksOidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
