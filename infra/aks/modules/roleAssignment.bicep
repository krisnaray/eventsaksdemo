// Role Assignment module
param principalId string
param roleDefinitionId string
param principalType string = 'ServicePrincipal'
param scopeResourceId string

// Generate a GUID for the role assignment name based on input parameters
var roleAssignmentNameGuid = guid('${principalId}-${roleDefinitionId}-${scopeResourceId}')

resource targetResource 'Microsoft.Resources/deployments@2023-07-01' existing = {
  name: last(split(scopeResourceId, '/'))
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleAssignmentNameGuid
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

output roleAssignmentId string = roleAssignment.id
