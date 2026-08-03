[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{4,49}$')]
    [string]$AutomationAccountName,

    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}(/resourceGroups/[^/]+)?(/providers/Microsoft\.Compute/virtualMachines/[^/]+)?$')]
    [string]$TargetScope,

    [ValidatePattern('^$|^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$LogAnalyticsWorkspaceResourceId = '',

    [string]$WorkbookDisplayName = 'Ghost NIC Hunter dashboard',

    [hashtable]$Tags = @{
        managedBy = 'vanRoojen LLC'
        workload  = 'ghost-nic-hunter'
    }
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$templateFile = Join-Path $repoRoot 'infra/main.bicep'
$runbookFile = Join-Path $repoRoot 'runbooks/Invoke-GhostNicMaintenance.ps1'
$workbookFile = Join-Path $repoRoot 'workbooks/ghostnic-dashboard.json'

foreach ($requiredFile in @($templateFile, $runbookFile, $workbookFile)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required deployment file was not found: $requiredFile"
    }
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

if ($WhatIfPreference) {
    [pscustomobject]@{
        AutomationAccount = $AutomationAccountName
        ResourceGroup     = $ResourceGroupName
        Location          = $Location
        TargetScope       = $TargetScope
        Runbook           = 'Invoke-GhostNicMaintenance'
        NextStep          = 'WhatIf only: no Azure resources, runbook content, or role assignments were changed.'
    }
    return
}

if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in $Location")) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $Tags | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($AutomationAccountName, 'Deploy Azure Automation account')) {
    New-AzResourceGroupDeployment `
        -Name "ghostnic-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))" `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $templateFile `
        -automationAccountName $AutomationAccountName `
        -location $Location `
        -logAnalyticsWorkspaceResourceId $LogAnalyticsWorkspaceResourceId `
        -workbookDisplayName $WorkbookDisplayName `
        -tags $Tags | Out-Null
}

$automationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
if (-not $automationAccount.Identity.PrincipalId) {
    throw "Automation account '$AutomationAccountName' has no system-assigned managed identity."
}

$runbookName = 'Invoke-GhostNicMaintenance'
$existingRunbook = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -ErrorAction SilentlyContinue
if ($existingRunbook) {
    if ($PSCmdlet.ShouldProcess($runbookName, 'Replace and publish runbook content')) {
        Remove-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -Force
        Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -Type PowerShell -Path $runbookFile -Published
    }
} elseif ($PSCmdlet.ShouldProcess($runbookName, 'Import and publish runbook')) {
    Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -Type PowerShell -Path $runbookFile -Published
}

if ($TargetScope) {
    $existingAssignment = Get-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -Scope $TargetScope -RoleDefinitionName 'Virtual Machine Contributor' -ErrorAction SilentlyContinue
    if (-not $existingAssignment -and $PSCmdlet.ShouldProcess($TargetScope, 'Grant Virtual Machine Contributor to Automation managed identity')) {
        New-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -RoleDefinitionName 'Virtual Machine Contributor' -Scope $TargetScope | Out-Null
    }
}

[pscustomobject]@{
    AutomationAccountId = $automationAccount.Id
    ManagedIdentityId   = $automationAccount.Identity.PrincipalId
    Runbook             = $runbookName
    RoleScope           = $TargetScope
    WorkbookEnabled     = -not [string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceResourceId)
    NextStep            = 'Start Invoke-GhostNicMaintenance with Operation=Detect and full VM resource IDs.'
}
