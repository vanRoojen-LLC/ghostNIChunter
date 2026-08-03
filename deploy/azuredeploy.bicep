targetScope = 'resourceGroup'

@description('Automation Account name. Leave blank to generate a unique name in the selected resource group.')
param automationAccountName string = ''

@description('Full resource IDs of the target resource groups. The Automation identity receives Virtual Machine Contributor on each group.')
param targetResourceGroupIds array

@description('Optional full resource ID of an existing Log Analytics workspace. Enables history collection and the workbook.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Public URI of the runbook source. Leave the default unless deploying a reviewed fork or pinned revision.')
param runbookScriptUri string = 'https://raw.githubusercontent.com/vanRoojen-LLC/ghostNIChunter/main/runbooks/Invoke-GhostNicMaintenance.ps1'

@description('Cache-busting revision or build identifier appended to the runbook source URI.')
param runbookCacheBust string = utcNow('yyyyMMddHHmmss')

var resolvedAutomationAccountName = empty(automationAccountName) ? toLower('aa-ghostnic-${take(uniqueString(resourceGroup().id, deployment().name), 10)}') : automationAccountName
var runbookName = 'Invoke-GhostNicMaintenance'
var tags = {
  managedBy: 'vanRoojen LLC'
  workload: 'ghost-nic-hunter'
  repository: 'https://github.com/vanRoojen-LLC/ghostNIChunter'
  sourceRevision: runbookCacheBust
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: resolvedAutomationAccountName
  location: resourceGroup().location
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

resource azAccountsModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Accounts'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Accounts'
    }
  }
}

resource azComputeModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Compute'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Compute'
    }
  }
}

resource configuredTargets 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'GhostNicTargetResourceGroupIds'
  properties: {
    description: 'One or more target resource-group IDs, separated by commas, semicolons, or new lines.'
    isEncrypted: false
    value: join(targetResourceGroupIds, '\n')
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: runbookName
  location: resourceGroup().location
  dependsOn: [
    azAccountsModule
    azComputeModule
  ]
  tags: tags
  properties: {
    description: 'Detects or explicitly removes Windows Azure ghosted NIC entries through VM Run Command.'
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: true
    publishContentLink: {
      uri: '${runbookScriptUri}?v=${runbookCacheBust}'
      version: '1.0.0.0'
    }
  }
}

module targetResourceGroupRoles 'target-resource-group-role.bicep' = [for targetResourceGroupId in targetResourceGroupIds: {
  name: 'ghostnic-rg-rbac-${take(uniqueString(targetResourceGroupId, resolvedAutomationAccountName), 12)}'
  scope: resourceGroup(split(targetResourceGroupId, '/')[2], split(targetResourceGroupId, '/')[4])
  params: {
    targetResourceGroupId: targetResourceGroupId
    automationPrincipalId: automationAccount.identity.principalId
  }
}]

resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  scope: automationAccount
  name: 'ghostnic-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
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

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: guid(resourceGroup().id, 'Ghost NIC Hunter dashboard', logAnalyticsWorkspaceResourceId)
  location: resourceGroup().location
  kind: 'shared'
  properties: {
    displayName: 'Ghost NIC Hunter dashboard'
    serializedData: loadTextContent('../workbooks/ghostnic-dashboard.json')
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceResourceId
    version: '1.0'
  }
}

output automationAccountName string = resolvedAutomationAccountName
output runbookName string = runbookName
output targetResourceGroupIds array = targetResourceGroupIds
