targetScope = 'resourceGroup'

@description('Name of the target VM in this resource group.')
param targetVmName string

@description('Full resource ID of the target VM.')
param targetVmResourceId string

@description('System-assigned managed identity principal ID for the Automation account.')
param automationPrincipalId string

var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

resource targetVm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: targetVmName
}

resource runCommandRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetVmResourceId, automationPrincipalId, virtualMachineContributorRoleDefinitionId)
  scope: targetVm
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleDefinitionId)
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
  }
}
