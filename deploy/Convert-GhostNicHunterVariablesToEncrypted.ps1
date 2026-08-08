<#
.SYNOPSIS
Migrates an existing Ghost NIC Hunter installation from normal to encrypted Automation variables.

.DESCRIPTION
Refuses nonterminal jobs, pauses the daily schedule, preserves normal values in process memory
only, removes obsolete persistent variables, recreates current variables encrypted, and verifies
the final state before restoring the schedule. A mixed state left by an interrupted migration is
resumable because existing encrypted variables are not replaced. Reverse migration is intentionally
unsupported because encrypted values cannot be read externally.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AutomationAccountName,

    [switch]$ConfirmMigration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmMigration) {
    throw 'Migration is blocked. Review the WhatIf result, then rerun with -ConfirmMigration.'
}

$requiredVariableNames = @(
    'GhostNicTargetResourceGroupIds'
    'GhostNicMaximumCandidateCount'
    'GhostNicExclusionTagName'
    'GhostNicScanExclusionValues'
    'GhostNicRemovalExclusionValues'
    'GhostNicPnpCleanWaitSeconds'
    'GhostNicRequireProblemCode45'
)
$legacyVariableNames = @('GhostNicOperation', 'GhostNicConfirmRemoval', 'GhostNicTargetVmResourceIds')
$knownVariableNames = @($requiredVariableNames + $legacyVariableNames)
$scheduleName = 'GhostNic-Daily-Detect-1230'
$terminalJobStatuses = @('Completed', 'Failed', 'Stopped')

function Get-VariableEncryptedState {
    param([Parameter(Mandatory)]$Variable)

    $property = $Variable.PSObject.Properties['Encrypted']
    if (-not $property) { $property = $Variable.PSObject.Properties['IsEncrypted'] }
    if (-not $property) {
        throw "Cannot determine the encryption mode of Automation variable '$($Variable.Name)'."
    }
    return [System.Convert]::ToBoolean($property.Value)
}

function Get-ActiveGhostNicJobs {
    $jobs = @(
        Get-AzAutomationJob `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop
    )
    return @(
        $jobs |
            Where-Object {
                $statusProperty = $_.PSObject.Properties['Status']
                -not $statusProperty -or [string]$statusProperty.Value -notin $terminalJobStatuses
            } |
            Sort-Object Id -Unique
    )
}

function New-EncryptedAutomationVariableFromCapture {
    param([Parameter(Mandatory)]$CapturedVariable)

    $parameters = @{
        ResourceGroupName = $ResourceGroupName
        AutomationAccountName = $AutomationAccountName
        Name = $CapturedVariable.Name
        Encrypted = $true
        Value = $CapturedVariable.Value
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CapturedVariable.Description)) {
        $parameters.Description = [string]$CapturedVariable.Description
    }
    New-AzAutomationVariable @parameters | Out-Null
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$automationAccount = Get-AzAutomationAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $AutomationAccountName `
    -ErrorAction Stop
if (-not $automationAccount) { throw "Automation account '$AutomationAccountName' was not found." }

$allVariables = @(
    Get-AzAutomationVariable `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -ErrorAction Stop
)
$unknownVariables = @($allVariables | Where-Object { $_.Name -like 'GhostNic*' -and $_.Name -notin $knownVariableNames })
if ($unknownVariables.Count -gt 0) {
    throw "Unsupported Ghost NIC Hunter variable(s) were found: $(($unknownVariables.Name | Sort-Object) -join ', '). Review them before migration."
}

$allVariableNames = @($allVariables | ForEach-Object { $_.Name })
$missingRequiredVariables = @($requiredVariableNames | Where-Object { $_ -notin $allVariableNames })
if ($missingRequiredVariables.Count -gt 0) {
    throw "Required variable(s) are missing: $(($missingRequiredVariables | Sort-Object) -join ', '). Redeploy or restore the current variable set before migration."
}

$currentVariables = @($allVariables | Where-Object { $_.Name -in $requiredVariableNames })
$legacyVariables = @($allVariables | Where-Object { $_.Name -in $legacyVariableNames })
$encryptedCurrentVariables = @($currentVariables | Where-Object { Get-VariableEncryptedState -Variable $_ })
$plaintextCurrentVariables = @($currentVariables | Where-Object { -not (Get-VariableEncryptedState -Variable $_) })

$migrationRequired = $plaintextCurrentVariables.Count -gt 0
$cleanupRequired = $legacyVariables.Count -gt 0
$resumingMixedState = $encryptedCurrentVariables.Count -gt 0 -and $plaintextCurrentVariables.Count -gt 0
if (-not $migrationRequired -and -not $cleanupRequired) {
    $result = [ordered]@{
        Succeeded = $true
        Changed = $false
        Reason = 'CurrentVariablesAlreadyEncrypted'
        VerifiedVariableCount = $encryptedCurrentVariables.Count
    }
    Write-Output "GHNIC_VARIABLE_MIGRATION:$($result | ConvertTo-Json -Compress)"
    return
}

$activeJobs = @(Get-ActiveGhostNicJobs)
if ($activeJobs.Count -gt 0) {
    throw "Migration requires an idle Automation account. Active job count: $($activeJobs.Count)."
}

$schedule = Get-AzAutomationSchedule `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $scheduleName `
    -ErrorAction SilentlyContinue
$scheduleWasEnabled = $false
if ($schedule) {
    $scheduleEnabledProperty = $schedule.PSObject.Properties['IsEnabled']
    if (-not $scheduleEnabledProperty) { $scheduleEnabledProperty = $schedule.PSObject.Properties['Enabled'] }
    if (-not $scheduleEnabledProperty) { throw "Cannot determine whether schedule '$scheduleName' is enabled." }
    $scheduleWasEnabled = [System.Convert]::ToBoolean($scheduleEnabledProperty.Value)
}

if ($WhatIfPreference) {
    [void]$PSCmdlet.ShouldProcess($AutomationAccountName, "Encrypt $($plaintextCurrentVariables.Count) current variable(s), remove $($legacyVariables.Count) obsolete variable(s), and verify the result")
    $result = [ordered]@{
        Succeeded = $true
        Changed = $false
        Reason = 'WhatIf'
        VariablesToEncrypt = @($plaintextCurrentVariables | ForEach-Object { $_.Name } | Sort-Object)
        ExistingEncryptedVariables = @($encryptedCurrentVariables | ForEach-Object { $_.Name } | Sort-Object)
        LegacyVariablesToRemove = @($legacyVariables | ForEach-Object { $_.Name } | Sort-Object)
        ScheduleWouldBePaused = $scheduleWasEnabled
        ResumingMixedState = $resumingMixedState
    }
    Write-Output "GHNIC_VARIABLE_MIGRATION:$($result | ConvertTo-Json -Depth 4 -Compress)"
    return
}

if (-not $PSCmdlet.ShouldProcess($AutomationAccountName, "Encrypt $($plaintextCurrentVariables.Count) current variable(s), remove $($legacyVariables.Count) obsolete variable(s), and verify the result")) {
    return
}

$capturedVariables = @(
    foreach ($variable in $plaintextCurrentVariables) {
        [pscustomobject]@{
            Name = [string]$variable.Name
            Description = [string]$variable.Description
            Value = $variable.Value
        }
    }
)
$createdEncryptedNames = [System.Collections.Generic.List[string]]::new()
$scheduleDisabledByScript = $false
$migrationStage = 'PauseSchedule'

try {
    if ($scheduleWasEnabled) {
        Set-AzAutomationSchedule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $scheduleName `
            -IsEnabled $false | Out-Null
        $scheduleDisabledByScript = $true
    }

    $migrationStage = 'RecheckActiveJobs'
    $activeJobs = @(Get-ActiveGhostNicJobs)
    if ($activeJobs.Count -gt 0) {
        throw "A job entered an active state after migration preflight. Active job count: $($activeJobs.Count)."
    }

    $migrationStage = 'RemoveNormalVariables'
    foreach ($variable in $plaintextCurrentVariables) {
        Remove-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $variable.Name `
            -Confirm:$false
    }

    $migrationStage = 'RemoveObsoleteVariables'
    foreach ($legacyVariable in $legacyVariables) {
        Remove-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $legacyVariable.Name `
            -Confirm:$false
    }

    $migrationStage = 'CreateEncryptedVariables'
    foreach ($capturedVariable in $capturedVariables) {
        New-EncryptedAutomationVariableFromCapture -CapturedVariable $capturedVariable
        $createdEncryptedNames.Add([string]$capturedVariable.Name)
    }

    $migrationStage = 'VerifyEncryptedVariables'
    $verifiedVariables = @(
        Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -ErrorAction Stop
    )
    $currentVariableNames = @($currentVariables | ForEach-Object { $_.Name })
    $verifiedVariableNames = @($verifiedVariables | ForEach-Object { $_.Name })
    $missingAfterMigration = @($currentVariableNames | Where-Object { $_ -notin $verifiedVariableNames })
    $notEncryptedAfterMigration = @(
        $verifiedVariables |
            Where-Object { $_.Name -in $currentVariableNames } |
            Where-Object { -not (Get-VariableEncryptedState -Variable $_) }
    )
    $legacyAfterMigration = @($verifiedVariables | Where-Object { $_.Name -in $legacyVariableNames })
    if ($missingAfterMigration.Count -gt 0 -or $notEncryptedAfterMigration.Count -gt 0 -or $legacyAfterMigration.Count -gt 0) {
        throw 'Post-migration verification failed. The schedule will remain disabled.'
    }

    if ($scheduleDisabledByScript) {
        $migrationStage = 'RestoreSchedule'
        Set-AzAutomationSchedule `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $scheduleName `
            -IsEnabled $true | Out-Null
        $scheduleDisabledByScript = $false
    }

    $result = [ordered]@{
        Succeeded = $true
        Changed = $true
        EncryptedVariableCount = $createdEncryptedNames.Count
        EncryptedVariables = @($createdEncryptedNames | Sort-Object)
        RemovedLegacyVariableCount = $legacyVariables.Count
        RemovedLegacyVariables = @($legacyVariables | ForEach-Object { $_.Name } | Sort-Object)
        VerifiedVariableCount = $currentVariables.Count
        ScheduleRestored = $scheduleWasEnabled
        ResumedMixedState = $resumingMixedState
    }
    Write-Output "GHNIC_VARIABLE_MIGRATION:$($result | ConvertTo-Json -Depth 4 -Compress)"
}
catch {
    $recoveryFailures = [System.Collections.Generic.List[string]]::new()

    foreach ($capturedVariable in $capturedVariables) {
        try {
            $existingVariable = Get-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $capturedVariable.Name `
                -ErrorAction SilentlyContinue
            if (-not $existingVariable) {
                New-EncryptedAutomationVariableFromCapture -CapturedVariable $capturedVariable
            }
        }
        catch {
            $recoveryFailures.Add([string]$capturedVariable.Name)
        }
    }

    $scheduleMessage = if ($scheduleDisabledByScript) { "Schedule '$scheduleName' remains disabled." } else { 'The migration did not disable the schedule.' }
    $recoveryMessage = if ($recoveryFailures.Count -gt 0) { " Recovery failed for variable(s): $(($recoveryFailures | Sort-Object) -join ', ')." } else { ' Captured current variables remain present or were restored. A retry can safely converge any remaining normal variables to encrypted storage.' }
    throw "Ghost NIC Hunter variable migration failed during stage '$migrationStage'. $scheduleMessage$recoveryMessage No variable values were written to output; review Azure activity logs for the underlying platform error."
}
