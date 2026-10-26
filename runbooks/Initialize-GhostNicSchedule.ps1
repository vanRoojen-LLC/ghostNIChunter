[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-f-]+/resourceGroups/[^/]+/providers/Microsoft\.Automation/automationAccounts/[^/]+$')]
    [string]$AutomationAccountResourceId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$RunbookName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ScheduleName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$JobScheduleId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ScheduleLinkerClientId,

    [Parameter(Mandatory)]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$AzureEnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ScheduleTimeZone,

    [Parameter(Mandatory)]
    [ValidatePattern('^(?:[01]\d|2[0-3]):[0-5]\d$')]
    [string]$ScheduleLocalTime,

    [Parameter(Mandatory)]
    [ValidateSet('Day', 'Hour')]
    [string]$ScheduleFrequency,

    [Parameter(Mandatory)]
    [ValidateRange(1, 24)]
    [int]$ScheduleInterval,

    [Parameter(Mandatory)]
    [bool]$ScheduleEnabled,

    [Parameter(Mandatory)]
    [ValidateSet('Detect', 'Remove')]
    [string]$ScheduledOperation,

    [Parameter(Mandatory)]
    [bool]$ScheduledConfirmRemoval,

    [Parameter(Mandatory)]
    [bool]$ScheduledRestartRemediatedVm,

    [Parameter(Mandatory)]
    [bool]$UseFreshnessFilter,

    [Parameter(Mandatory)]
    [ValidateRange(1, 168)]
    [int]$FreshnessHours,

    [Parameter(Mandatory)]
    [ValidateRange(0, 6)]
    [int]$OfflineRetryCount,

    [Parameter(Mandatory)]
    [ValidateRange(0, 120)]
    [int]$OfflineRetryDelayMinutes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JobSchedules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$DefaultProfile
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-AzRestMethod -Path $Path -Method GET -DefaultProfile $DefaultProfile
            return ($response.Content | ConvertFrom-Json)
        }
        catch {
            if ($attempt -eq 30) {
                throw
            }

            Start-Sleep -Seconds 10
        }
    }
}

function Get-ScheduleTimeZoneInfo {
    param([Parameter(Mandatory)][string]$Id)

    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($Id)
    }
    catch {
        $windowsTimeZoneByIanaId = @{
            'America/Los_Angeles' = 'Pacific Standard Time'
            'America/Denver' = 'Mountain Standard Time'
            'America/Chicago' = 'Central Standard Time'
            'America/New_York' = 'Eastern Standard Time'
            'Etc/UTC' = 'UTC'
            'UTC' = 'UTC'
        }
        if (-not $windowsTimeZoneByIanaId.ContainsKey($Id)) { throw }
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($windowsTimeZoneByIanaId[$Id])
    }
}

function Get-NextScheduleStartTime {
    param(
        [Parameter(Mandatory)][string]$TimeZoneId,
        [Parameter(Mandatory)][string]$LocalTime,
        [Parameter(Mandatory)][ValidateSet('Day', 'Hour')][string]$Frequency
    )

    $timeZone = Get-ScheduleTimeZoneInfo -Id $TimeZoneId
    if ($Frequency -eq 'Hour') {
        return [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')
    }
    $timeParts = $LocalTime.Split(':')
    $nowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $timeZone)
    $candidate = [DateTime]::SpecifyKind(
        $nowLocal.Date.AddHours([int]$timeParts[0]).AddMinutes([int]$timeParts[1]),
        [DateTimeKind]::Unspecified
    )
    if ($candidate -le $nowLocal.AddMinutes(5)) { $candidate = $candidate.AddDays(1) }
    $offset = $timeZone.GetUtcOffset($candidate)
    return ([DateTimeOffset]::new($candidate, $offset)).ToString('o')
}

Disable-AzContextAutosave -Scope Process | Out-Null

$resourceIdParts = $AutomationAccountResourceId.Trim('/') -split '/'
$subscriptionId = $resourceIdParts[1]
$azureContext = (Connect-AzAccount -Identity -AccountId $ScheduleLinkerClientId -Environment $AzureEnvironmentName).Context
$azureContext = Set-AzContext -SubscriptionId $subscriptionId -DefaultProfile $azureContext

if ($ScheduledOperation -eq 'Remove' -and -not $ScheduledConfirmRemoval) {
    throw 'A scheduled removal requires ScheduledConfirmRemoval=true.'
}
if ($ScheduledOperation -eq 'Detect' -and ($ScheduledConfirmRemoval -or $ScheduledRestartRemediatedVm)) {
    throw 'Detect schedules cannot confirm removal or restart remediated VMs.'
}

$collectionPath = "$AutomationAccountResourceId/jobSchedules?api-version=2023-11-01"
$jobSchedules = Get-JobSchedules -Path $collectionPath -DefaultProfile $azureContext
$existingAssociation = @($jobSchedules.value | Where-Object {
        $_.properties.runbook.name -eq $RunbookName -and
        $_.properties.schedule.name -eq $ScheduleName
    })

# Job schedule parameters are immutable and the collection API can omit them. Reconcile
# every deployment by deleting only this runbook/schedule association, waiting for Azure
# Automation to release it, and then recreating it with the requested safe parameters.
foreach ($association in $existingAssociation) {
    $associationId = [string]$association.properties.jobScheduleId
    if ([string]::IsNullOrWhiteSpace($associationId)) { $associationId = ([string]$association.id -split '/')[-1] }
    $existingAssociationPath = "$AutomationAccountResourceId/jobSchedules/$associationId`?api-version=2023-11-01"
    Invoke-AzRestMethod -Path $existingAssociationPath -Method DELETE -DefaultProfile $azureContext | Out-Null
}

if ($existingAssociation.Count -gt 0) {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $jobSchedules = Get-JobSchedules -Path $collectionPath -DefaultProfile $azureContext
        $remainingAssociation = @($jobSchedules.value | Where-Object {
                $_.properties.runbook.name -eq $RunbookName -and
                $_.properties.schedule.name -eq $ScheduleName
            })
        if ($remainingAssociation.Count -eq 0) { break }
        if ($attempt -eq 30) { throw 'Timed out waiting for the existing job schedule association to be deleted.' }
        Start-Sleep -Seconds 5
    }
}

if (-not $ScheduleEnabled) {
    $schedulePath = "$AutomationAccountResourceId/schedules/$ScheduleName`?api-version=2023-11-01"
    try {
        Invoke-AzRestMethod -Path $schedulePath -Method DELETE -DefaultProfile $azureContext | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)404|not.?found') { throw }
    }
    $scheduleResult = [ordered]@{
        Succeeded = $true
        Changed = ($existingAssociation.Count -gt 0)
        Reason = 'ScheduleDisabledAndAssociationRemoved'
        Operation = $ScheduledOperation
        ScheduleName = $ScheduleName
    }
    Write-Output "GHNIC_SCHEDULE:$($scheduleResult | ConvertTo-Json -Compress)"
    return
}

$scheduleStartTime = Get-NextScheduleStartTime -TimeZoneId $ScheduleTimeZone -LocalTime $ScheduleLocalTime -Frequency $ScheduleFrequency
$scheduleCadence = if ($ScheduleFrequency -eq 'Day') { "daily at $ScheduleLocalTime in $ScheduleTimeZone" } else { "every $ScheduleInterval hour(s)" }
$scheduleBody = @{
    name = $ScheduleName
    properties = @{
        description = "Runs Ghost NIC $($ScheduledOperation.ToLowerInvariant()) $scheduleCadence. Administrators can adjust or disable this schedule in Azure Automation."
        frequency = $ScheduleFrequency
        interval = $ScheduleInterval
        startTime = $scheduleStartTime
        timeZone = $ScheduleTimeZone
    }
} | ConvertTo-Json -Depth 6 -Compress
$schedulePath = "$AutomationAccountResourceId/schedules/$ScheduleName`?api-version=2023-11-01"
Invoke-AzRestMethod -Path $schedulePath -Method PUT -Payload $scheduleBody -DefaultProfile $azureContext | Out-Null

$scheduledParameters = [ordered]@{
    Operation = $ScheduledOperation
    UseFreshnessFilter = $UseFreshnessFilter.ToString().ToLowerInvariant()
    FreshnessHours = $FreshnessHours.ToString()
    OfflineRetryCount = $OfflineRetryCount.ToString()
    OfflineRetryDelayMinutes = $OfflineRetryDelayMinutes.ToString()
}
if ($ScheduledOperation -eq 'Remove') {
    $scheduledParameters['ConfirmRemoval'] = $ScheduledConfirmRemoval.ToString().ToLowerInvariant()
    $scheduledParameters['RestartRemediatedVm'] = $ScheduledRestartRemediatedVm.ToString().ToLowerInvariant()
}
$associationBody = @{
    properties = @{
        parameters = $scheduledParameters
        runbook = @{
            name = $RunbookName
        }
        schedule = @{
            name = $ScheduleName
        }
    }
} | ConvertTo-Json -Depth 6 -Compress

$associationPath = "$AutomationAccountResourceId/jobSchedules/$JobScheduleId`?api-version=2023-11-01"

try {
    Invoke-AzRestMethod -Path $associationPath -Method PUT -Payload $associationBody -DefaultProfile $azureContext | Out-Null
}
catch {
    # A concurrent deployment may have created the association after the initial list.
    $createError = $_
    $jobSchedules = Get-JobSchedules -Path $collectionPath -DefaultProfile $azureContext
    $existingAssociation = @($jobSchedules.value | Where-Object {
            $_.properties.runbook.name -eq $RunbookName -and
            $_.properties.schedule.name -eq $ScheduleName
        })

    if ($existingAssociation.Count -eq 0) {
        throw $createError
    }
}

$scheduleResult = [ordered]@{
    Succeeded = $true
    Changed = $true
    Reason = 'ScheduleAndAssociationReconciled'
    Operation = $ScheduledOperation
    ScheduleName = $ScheduleName
    ScheduleEnabled = $true
    StartTime = $scheduleStartTime
}
Write-Output "GHNIC_SCHEDULE:$($scheduleResult | ConvertTo-Json -Compress)"
