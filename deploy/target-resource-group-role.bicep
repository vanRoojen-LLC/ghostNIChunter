targetScope = 'resourceGroup'

@description('Full resource ID of the target resource group.')
param targetResourceGroupId string

@description('System-assigned managed identity principal ID for the Automation account.')
param automationPrincipalId string

var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

resource runCommandRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetResourceGroupId, automationPrincipalId, virtualMachineContributorRoleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleDefinitionId)
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}
