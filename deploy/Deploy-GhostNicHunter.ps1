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

    [ValidatePattern('^$|^[a-zA-Z][a-zA-Z0-9-]{4,49}$')]
    [string]$AutomationAccountName = '',

    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+$')]
    [string[]]$TargetResourceGroupIds,

    [ValidatePattern('^$|^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$LogAnalyticsWorkspaceResourceId = '',

    [string]$WorkbookDisplayName = 'Ghost NIC Hunter dashboard',

    [string]$DailyScheduleTimeZone = 'America/Los_Angeles',

    [hashtable]$Tags = @{
        managedBy = 'vanRoojen LLC'
        workload  = 'ghost-nic-hunter'
        sourceRepository = 'vanRoojen-LLC/ghostNIChunter'
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
try { $sourceRevision = (git -C $repoRoot rev-parse HEAD 2>$null).Trim() } catch { $sourceRevision = 'unknown' }
$Tags.sourceRevision = if ($sourceRevision) { $sourceRevision } else { 'unknown' }
$Tags.deploymentTimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
$Tags.component = 'automation'
$targetResourceGroupIds = @($TargetResourceGroupIds | ForEach-Object { $_.TrimEnd('/') } | Select-Object -Unique)
if (-not $targetResourceGroupIds) { throw 'At least one target resource group ID is required.' }
if ([string]::IsNullOrWhiteSpace($AutomationAccountName)) {
    $suffix = Get-Random -Minimum 1000 -Maximum 10000
    $AutomationAccountName = "aa-ghostnic-$($Location.ToLowerInvariant())-$suffix"
    if ($AutomationAccountName.Length -gt 50) { $AutomationAccountName = $AutomationAccountName.Substring(0, 50) }
}

if ($WhatIfPreference) {
    [pscustomobject]@{
        AutomationAccount = $AutomationAccountName
        ResourceGroup     = $ResourceGroupName
        Location          = $Location
        TargetResourceGroupIds = $targetResourceGroupIds
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
        -targetResourceGroupIds $targetResourceGroupIds `
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

$dailyScheduleName = 'GhostNic-Daily-Detect-1230'
$dailySchedule = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $dailyScheduleName -ErrorAction SilentlyContinue
if (-not $dailySchedule -and $PSCmdlet.ShouldProcess($dailyScheduleName, "Create daily 12:30 PM schedule in $DailyScheduleTimeZone")) {
    $dailySchedule = New-AzAutomationSchedule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $dailyScheduleName `
        -StartTime ((Get-Date '12:30:00').AddDays(1)) `
        -DayInterval 1 `
        -TimeZone $DailyScheduleTimeZone `
        -Description 'Runs Ghost NIC detection daily at 12:30 PM local time. Administrators can adjust this schedule in Azure Automation.'
}

$scheduledRunbook = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ScheduleName $dailyScheduleName -RunbookName $runbookName -ErrorAction SilentlyContinue
if (-not $scheduledRunbook -and $PSCmdlet.ShouldProcess($runbookName, "Link to $dailyScheduleName in Detect mode")) {
    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName $runbookName `
        -ScheduleName $dailyScheduleName `
        -Parameters @{ Operation = 'Detect' } | Out-Null
}

foreach ($targetResourceGroupId in $targetResourceGroupIds) {
    $existingAssignment = Get-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -Scope $targetResourceGroupId -RoleDefinitionName 'Virtual Machine Contributor' -ErrorAction SilentlyContinue
    if (-not $existingAssignment -and $PSCmdlet.ShouldProcess($targetResourceGroupId, 'Grant Virtual Machine Contributor to Automation managed identity')) {
        New-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -RoleDefinitionName 'Virtual Machine Contributor' -Scope $targetResourceGroupId | Out-Null
    }
}

[pscustomobject]@{
    AutomationAccountId = $automationAccount.Id
    ManagedIdentityId   = $automationAccount.Identity.PrincipalId
    Runbook             = $runbookName
    TargetResourceGroupIds = $targetResourceGroupIds
    WorkbookEnabled     = $true
    DailySchedule       = $dailyScheduleName
    DailyScheduleTimeZone = $DailyScheduleTimeZone
    NextStep            = 'Start Invoke-GhostNicMaintenance with Operation=Detect; target VMs will be discovered from the configured resource groups.'
}
