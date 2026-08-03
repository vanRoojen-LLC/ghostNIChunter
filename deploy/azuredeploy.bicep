targetScope = 'resourceGroup'

@description('Comma-separated full resource IDs of target resource groups. The Automation identity receives Virtual Machine Contributor on each group.')
param targetResourceGroupIds string

@description('Public URI of the runbook source. Leave the default unless deploying a reviewed fork or pinned revision.')
param runbookScriptUri string = 'https://raw.githubusercontent.com/vanRoojen-LLC/ghostNIChunter/main/runbooks/Invoke-GhostNicMaintenance.ps1'

@description('Git branch or commit revision used in the published runbook URL. Change this when deploying a new revision.')
param runbookCacheBust string = 'main'

var resolvedAutomationAccountName = toLower('aa-ghostnic-${take(uniqueString(resourceGroup().id, deployment().name), 10)}')
var resolvedTargetResourceGroupIds = [for targetResourceGroupId in split(targetResourceGroupIds, ','): trim(targetResourceGroupId)]
var runbookName = 'Invoke-GhostNicMaintenance'
var versionedRunbookUri = replace(runbookScriptUri, '/main/', '/${runbookCacheBust}/')
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
    value: join(resolvedTargetResourceGroupIds, '\n')
  }
}

var resolvedWorkspaceName = 'law-ghostnic-${take(uniqueString(resourceGroup().id, resolvedAutomationAccountName), 12)}'
resource generatedWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: resolvedWorkspaceName
  location: resourceGroup().location
  tags: union(tags, { component: 'log-analytics' })
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}
var workspaceId = generatedWorkspace.id

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
      uri: versionedRunbookUri
      version: '1.0.0.0'
    }
  }
}

module targetResourceGroupRoles 'target-resource-group-role.bicep' = [for targetResourceGroupId in resolvedTargetResourceGroupIds: {
  name: 'ghostnic-rg-rbac-${take(uniqueString(targetResourceGroupId, resolvedAutomationAccountName), 12)}'
  scope: resourceGroup(split(targetResourceGroupId, '/')[2], split(targetResourceGroupId, '/')[4])
  params: {
    targetResourceGroupId: targetResourceGroupId
    automationPrincipalId: automationAccount.identity.principalId
  }
}]

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
  name: guid(resourceGroup().id, 'Ghost NIC Hunter dashboard', workspaceId)
  location: resourceGroup().location
  kind: 'shared'
  tags: union(tags, { component: 'workbook' })
  properties: {
    displayName: 'Ghost NIC Hunter dashboard'
    serializedData: loadTextContent('../workbooks/ghostnic-dashboard.json')
    category: 'workbook'
    sourceId: workspaceId
    version: '1.0'
  }
}

output automationAccountName string = resolvedAutomationAccountName
output runbookName string = runbookName
output targetResourceGroupIds array = resolvedTargetResourceGroupIds
output workspaceId string = workspaceId
output workbookId string = workbook.id
