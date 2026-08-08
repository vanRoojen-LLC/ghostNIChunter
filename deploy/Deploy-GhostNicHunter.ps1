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

    [bool]$EncryptAutomationVariables = $true,

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
$configurationRunbookFile = Join-Path $repoRoot 'runbooks/Configure-GhostNicHunter.ps1'
$workbookFile = Join-Path $repoRoot 'workbooks/ghostnic-dashboard.json'

foreach ($requiredFile in @($templateFile, $runbookFile, $configurationRunbookFile, $workbookFile)) {
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

$legacyVariableNames = @('GhostNicOperation', 'GhostNicConfirmRemoval', 'GhostNicTargetVmResourceIds')
$existingResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
$existingAutomationVariables = @()
$legacyVariables = @()

if ($existingResourceGroup) {
    $existingAutomationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue
    if ($existingAutomationAccount) {
        $existingAutomationVariables = @(Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName)
        $legacyVariables = @($existingAutomationVariables | Where-Object { $_.Name -in $legacyVariableNames })

        $modeMismatches = @(
            $existingAutomationVariables |
                Where-Object { $_.Name -like 'GhostNic*' -and $_.Name -notin $legacyVariableNames } |
                Where-Object {
                    $encryptionProperty = $_.PSObject.Properties['Encrypted']
                    if (-not $encryptionProperty) { $encryptionProperty = $_.PSObject.Properties['IsEncrypted'] }
                    if (-not $encryptionProperty) {
                        throw "Cannot determine the encryption mode of existing Automation variable '$($_.Name)'."
                    }
                    [System.Convert]::ToBoolean($encryptionProperty.Value) -ne $EncryptAutomationVariables
                }
        )

        if ($modeMismatches.Count -gt 0) {
            $requestedMode = if ($EncryptAutomationVariables) { 'encrypted' } else { 'normal' }
            $mismatchNames = ($modeMismatches.Name | Sort-Object) -join ', '
            throw "Automation variable encryption mode is immutable. Existing variable(s) do not match requested $requestedMode mode: $mismatchNames. Choose the existing mode or delete and recreate those variables before deployment."
        }
    }
}

if ($WhatIfPreference) {
    [pscustomobject]@{
        AutomationAccount = $AutomationAccountName
        ResourceGroup     = $ResourceGroupName
        Location          = $Location
        TargetResourceGroupIds = $targetResourceGroupIds
        Runbook           = 'Invoke-GhostNicMaintenance'
        ConfigurationRunbook = 'Configure-GhostNicHunter'
        AutomationVariablesEncrypted = $EncryptAutomationVariables
        LegacyVariablesToRemove = @($legacyVariables | ForEach-Object { $_.Name })
        NextStep          = 'WhatIf only: no Azure resources, runbook content, or role assignments were changed.'
    }
    return
}

if (-not $existingResourceGroup) {
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
        -encryptAutomationVariables $EncryptAutomationVariables `
        -tags $Tags | Out-Null
}

$automationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
if (-not $automationAccount.Identity.PrincipalId) {
    throw "Automation account '$AutomationAccountName' has no system-assigned managed identity."
}

$runbookName = 'Invoke-GhostNicMaintenance'
$configurationRunbookName = 'Configure-GhostNicHunter'
$runbookDefinitions = @(
    @{ Name = $runbookName; Path = $runbookFile }
    @{ Name = $configurationRunbookName; Path = $configurationRunbookFile }
)

foreach ($definition in $runbookDefinitions) {
    $existingRunbook = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $definition.Name -ErrorAction SilentlyContinue
    if ($existingRunbook) {
        if ($PSCmdlet.ShouldProcess($definition.Name, 'Replace and publish runbook content')) {
            Remove-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $definition.Name -Force
            Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $definition.Name -Type PowerShell -Path $definition.Path -Published
        }
    } elseif ($PSCmdlet.ShouldProcess($definition.Name, 'Import and publish runbook')) {
        Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $definition.Name -Type PowerShell -Path $definition.Path -Published
    }
}

foreach ($legacyVariable in $legacyVariables) {
    if ($PSCmdlet.ShouldProcess($legacyVariable.Name, 'Remove obsolete persistent Ghost NIC Hunter variable')) {
        Remove-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $legacyVariable.Name `
            -Confirm:$false
    }
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

try {
    foreach ($targetResourceGroupId in $targetResourceGroupIds) {
        $targetSubscriptionId = ($targetResourceGroupId -split '/')[2]
        Set-AzContext -SubscriptionId $targetSubscriptionId | Out-Null
        $existingAssignment = Get-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -Scope $targetResourceGroupId -RoleDefinitionName 'Virtual Machine Contributor' -ErrorAction SilentlyContinue
        if (-not $existingAssignment -and $PSCmdlet.ShouldProcess($targetResourceGroupId, 'Grant Virtual Machine Contributor to Automation managed identity')) {
            New-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -RoleDefinitionName 'Virtual Machine Contributor' -Scope $targetResourceGroupId | Out-Null
        }
    }
}
finally {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

[pscustomobject]@{
    AutomationAccountId = $automationAccount.Id
    ManagedIdentityId   = $automationAccount.Identity.PrincipalId
    Runbook             = $runbookName
    ConfigurationRunbook = $configurationRunbookName
    AutomationVariablesEncrypted = $EncryptAutomationVariables
    RemovedLegacyVariables = @($legacyVariables | ForEach-Object { $_.Name })
    TargetResourceGroupIds = $targetResourceGroupIds
    WorkbookEnabled     = $true
    DailySchedule       = $dailyScheduleName
    DailyScheduleTimeZone = $DailyScheduleTimeZone
    NextStep            = 'Start Invoke-GhostNicMaintenance with Operation=Detect; target VMs will be discovered from the configured resource groups.'
}
