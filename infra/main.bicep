@description('Azure region for the Automation account.')
param location string = resourceGroup().location

@description('Name of the Azure Automation account.')
param automationAccountName string

@description('Tags applied to the Azure Automation account.')
param tags object = {
  managedBy: 'vanRoojen LLC'
  workload: 'ghost-nic-hunter'
}

@description('Existing Log Analytics workspace resource ID. Leave empty to deploy without history collection or workbook.')
param logAnalyticsWorkspaceResourceId string = ''

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
  name: guid(resourceGroup().id, workbookDisplayName, logAnalyticsWorkspaceResourceId)
  location: resourceGroup().location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: loadTextContent('../workbooks/ghostnic-dashboard.json')
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceResourceId
    version: '1.0'
  }
}

output automationAccountId string = automationAccount.id
output principalId string = automationAccount.identity.principalId
output workbookId string = empty(logAnalyticsWorkspaceResourceId) ? '' : workbook.id
