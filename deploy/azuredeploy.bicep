targetScope = 'resourceGroup'

@description('Comma-separated full resource IDs of target resource groups. The Automation identity receives Virtual Machine Contributor on each group.')
param targetResourceGroupIds string

@description('Deployment timestamp used to choose a future first run for the daily schedule.')
param deploymentTime string = utcNow()

var resolvedAutomationAccountName = toLower('aa-ghostnic-${take(uniqueString(subscription().id, resourceGroup().id, 'ghostnic'), 10)}')
var resolvedTargetResourceGroupIds = [for targetResourceGroupId in split(targetResourceGroupIds, ','): trim(targetResourceGroupId)]
var runbookName = 'Invoke-GhostNicMaintenance'
var dailyScheduleName = 'GhostNic-Daily-Detect-1230'
var dailyScheduleTimeZone = 'America/Los_Angeles'
var dailyScheduleStartTime = '${substring(dateTimeAdd(deploymentTime, 'P1D'), 0, 10)}T12:30:00'
var versionedRunbookUri = 'https://raw.githubusercontent.com/vanRoojen-LLC/ghostNIChunter/main/runbooks/Invoke-GhostNicMaintenance-20260803-4.ps1'
var tags = {
  managedBy: 'vanRoojen LLC'
  workload: 'ghost-nic-hunter'
  repository: 'https://github.com/vanRoojen-LLC/ghostNIChunter'
  sourceRevision: '20260803-4'
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
    value: '"${join(resolvedTargetResourceGroupIds, '\n')}"'
  }
}

var runtimeVariableDefinitions = [
  { name: 'GhostNicOperation', description: 'Default mode: Detect or Remove.', value: '"Detect"' }
  { name: 'GhostNicConfirmRemoval', description: 'Must be true, together with Operation=Remove, before remediation is allowed.', value: 'false' }
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
    isEncrypted: false
    value: definition.value
  }
}]

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
    runtimeVariables
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

resource dailyDetectionSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: dailyScheduleName
  properties: {
    description: 'Runs Ghost NIC detection daily at 12:30 PM Pacific time. Administrators can adjust this schedule in Azure Automation.'
    frequency: 'Day'
    interval: 1
    startTime: dailyScheduleStartTime
    timeZone: dailyScheduleTimeZone
  }
}

resource dailyDetectionJobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  name: guid(automationAccount.id, runbookName, dailyScheduleName)
  dependsOn: [
    runbook
    dailyDetectionSchedule
  ]
  properties: {
    parameters: {
      Operation: 'Detect'
    }
    runbook: {
      name: runbookName
    }
    schedule: {
      name: dailyScheduleName
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
output dailyScheduleName string = dailyScheduleName
output dailyScheduleTimeZone string = dailyScheduleTimeZone
