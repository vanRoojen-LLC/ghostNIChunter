@description('Azure region for the Automation account.')
param location string = resourceGroup().location

@description('Name of the Azure Automation account.')
param automationAccountName string

@description('Tags applied to the Azure Automation account.')
param tags object = {
  managedBy: 'vanRoojen LLC'
  workload: 'ghost-nic-hunter'
}

@description('Existing Log Analytics workspace resource ID. Leave empty to create a dedicated workspace.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional name for the generated Log Analytics workspace.')
param logAnalyticsWorkspaceName string = ''

@description('Target VM resource-group IDs used by the runbook for discovery. IDs can span subscriptions accessible to the Automation identity.')
param targetResourceGroupIds array = []

@description('Initial storage mode for Ghost NIC Hunter Automation variables. Keep enabled to satisfy encryption policies; disable only when operators must read values in the portal. Existing variables must be deleted and recreated to change modes.')
param encryptAutomationVariables bool = true

@description('Friendly display name for the Azure Monitor workbook.')
param workbookDisplayName string = 'Ghost NIC Hunter dashboard'

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: true
    sku: {
      name: 'Basic'
    }
  }
}

resource targetResourceGroups 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'GhostNicTargetResourceGroupIds'
  properties: {
    description: 'Target resource-group IDs, one per line.'
    isEncrypted: encryptAutomationVariables
    value: '"${join(targetResourceGroupIds, '\n')}"'
  }
}

var runtimeVariableDefinitions = [
  { name: 'GhostNicMaximumCandidateCount', description: 'Safety ceiling for confirmed ghost NIC candidates on one VM.', value: '1000' }
  { name: 'GhostNicExclusionTagName', description: 'VM tag used to exclude scanning or removal.', value: '"ghostNicHunterExclusions"' }
  { name: 'GhostNicScanExclusionValues', description: 'Comma-separated tag values that prevent scanning.', value: '"scan,all"' }
  { name: 'GhostNicRemovalExclusionValues', description: 'Comma-separated tag values that prevent removal while allowing detection.', value: '"remove,all"' }
  { name: 'GhostNicPnpCleanWaitSeconds', description: 'Seconds to wait after PnpClean before pnputil fallback.', value: '10' }
  { name: 'GhostNicRequireProblemCode45', description: 'Require CM_PROB_PHANTOM code 45 before pnputil removal.', value: 'true' }
]

resource runtimeVariables 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = [for definition in runtimeVariableDefinitions: {
  parent: automationAccount
  name: definition.name
  properties: {
    description: definition.description
    isEncrypted: encryptAutomationVariables
    value: definition.value
  }
}]

var resolvedWorkspaceName = empty(logAnalyticsWorkspaceName) ? 'law-ghostnic-${take(uniqueString(resourceGroup().id, automationAccount.name), 12)}' : logAnalyticsWorkspaceName
resource generatedWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if (empty(logAnalyticsWorkspaceResourceId)) {
  name: resolvedWorkspaceName
  location: location
  tags: union(tags, { component: 'log-analytics' })
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}
resource existingWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: split(logAnalyticsWorkspaceResourceId, '/')[8]
  scope: resourceGroup(split(logAnalyticsWorkspaceResourceId, '/')[2], split(logAnalyticsWorkspaceResourceId, '/')[4])
}
var workspaceId = empty(logAnalyticsWorkspaceResourceId) ? generatedWorkspace.id : existingWorkspace.id

resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: automationAccount
  name: 'ghostnic-to-log-analytics'
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
    metrics: []
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, workbookDisplayName, workspaceId)
  location: resourceGroup().location
  kind: 'shared'
  tags: union(tags, { component: 'workbook' })
  properties: {
    displayName: workbookDisplayName
    serializedData: loadTextContent('../workbooks/ghostnic-dashboard.json')
    category: 'workbook'
    sourceId: workspaceId
    version: '1.0'
  }
}

output automationAccountId string = automationAccount.id
output principalId string = automationAccount.identity.principalId
output automationVariablesEncrypted bool = encryptAutomationVariables
output workspaceId string = workspaceId
output workbookId string = workbook.id
