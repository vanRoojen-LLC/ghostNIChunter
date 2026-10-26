<#
.SYNOPSIS
Detects or removes ghosted NIC registry entries on Azure Windows VMs through Run Command.

.DESCRIPTION
Runs with the Automation account's system-assigned managed identity. Removal is intentionally
fail-closed: it requires Operation=Remove and ConfirmRemoval=$true.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [string]$TargetVmResourceIds = '',

    [string]$TargetResourceGroupIds = '',

    [string]$Operation = '',

    [Nullable[bool]]$ConfirmRemoval,

    [Nullable[int]]$MaximumCandidateCount,

    [string]$ExclusionTagName = '',
    [string]$ScanExclusionValues = '',
    [string]$RemovalExclusionValues = '',
    [Nullable[int]]$PnpCleanWaitSeconds,
    [Nullable[bool]]$RequireProblemCode45,
    [Nullable[int]]$OfflineRetryCount,
    [Nullable[int]]$OfflineRetryDelayMinutes,
    [Nullable[bool]]$RestartRemediatedVm,
    [Nullable[bool]]$UseFreshnessFilter,
    [Nullable[int]]$FreshnessHours
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GhostNicAutomationVariable {
    param([Parameter(Mandatory)][string]$Name, $Default)
    try {
        $value = Get-AutomationVariable -Name $Name -ErrorAction Stop
        if ($null -ne $value -and -not ([string]$value).Equals('')) { return $value }
    } catch { }
    return $Default
}

function ConvertTo-GhostNicTargetList {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $trimmedValue = $Value.Trim()
    if ($trimmedValue.StartsWith('[')) {
        try {
            return @(
                $trimmedValue |
                    ConvertFrom-Json -ErrorAction Stop |
                    ForEach-Object { [string]$_ } |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ }
            )
        } catch {
            throw 'Target lists must be a single resource ID, comma/semicolon/newline-separated IDs, or a JSON string array.'
        }
    }

    return @($Value -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ([string]::IsNullOrWhiteSpace($Operation)) { $Operation = 'Detect' }
if ($Operation -notin @('Detect', 'Remove')) { throw "Invalid GhostNicOperation '$Operation'. Use Detect or Remove." }
if ($null -eq $ConfirmRemoval) { $ConfirmRemoval = $false }
if ($null -eq $MaximumCandidateCount) { $MaximumCandidateCount = [int](Get-GhostNicAutomationVariable 'GhostNicMaximumCandidateCount' 1000) }
if ($MaximumCandidateCount -lt 1 -or $MaximumCandidateCount -gt 10000) { throw 'GhostNicMaximumCandidateCount must be between 1 and 10000.' }
if ([string]::IsNullOrWhiteSpace($ExclusionTagName)) { $ExclusionTagName = [string](Get-GhostNicAutomationVariable 'GhostNicExclusionTagName' 'ghostNicHunterExclusions') }
if ([string]::IsNullOrWhiteSpace($ScanExclusionValues)) { $ScanExclusionValues = [string](Get-GhostNicAutomationVariable 'GhostNicScanExclusionValues' 'scan,all') }
if ([string]::IsNullOrWhiteSpace($RemovalExclusionValues)) { $RemovalExclusionValues = [string](Get-GhostNicAutomationVariable 'GhostNicRemovalExclusionValues' 'remove,all') }
if ($null -eq $PnpCleanWaitSeconds) { $PnpCleanWaitSeconds = [int](Get-GhostNicAutomationVariable 'GhostNicPnpCleanWaitSeconds' 10) }
if ($PnpCleanWaitSeconds -lt 0 -or $PnpCleanWaitSeconds -gt 300) { throw 'GhostNicPnpCleanWaitSeconds must be between 0 and 300.' }
if ($null -eq $RequireProblemCode45) { $RequireProblemCode45 = [System.Convert]::ToBoolean((Get-GhostNicAutomationVariable 'GhostNicRequireProblemCode45' $true)) }
if ($null -eq $OfflineRetryCount) { $OfflineRetryCount = 2 }
if ($OfflineRetryCount -lt 0 -or $OfflineRetryCount -gt 6) { throw 'OfflineRetryCount must be between 0 and 6.' }
if ($null -eq $OfflineRetryDelayMinutes) { $OfflineRetryDelayMinutes = 30 }
if ($OfflineRetryDelayMinutes -lt 0 -or $OfflineRetryDelayMinutes -gt 120) { throw 'OfflineRetryDelayMinutes must be between 0 and 120.' }
if ($null -eq $RestartRemediatedVm) { $RestartRemediatedVm = $false }
if ($null -eq $UseFreshnessFilter) { $UseFreshnessFilter = $false }
if ($null -eq $FreshnessHours) { $FreshnessHours = 26 }
if ($FreshnessHours -lt 1 -or $FreshnessHours -gt 168) { throw 'FreshnessHours must be between 1 and 168.' }
$scanExclusions = @($ScanExclusionValues -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$removalExclusions = @($RemovalExclusionValues -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })

if ($Operation -eq 'Remove' -and -not $ConfirmRemoval) {
    throw 'Removal is blocked. Set both Operation=Remove and ConfirmRemoval=$true after reviewing a detection job and confirming a VM recovery point.'
}

$targetVmResourceIdList = @(ConvertTo-GhostNicTargetList -Value $TargetVmResourceIds)
$targetResourceGroupIdList = @(ConvertTo-GhostNicTargetList -Value $TargetResourceGroupIds)

if ($targetResourceGroupIdList.Count -eq 0) {
    $configuredGroups = Get-AutomationVariable -Name 'GhostNicTargetResourceGroupIds' -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($configuredGroups)) {
        $targetResourceGroupIdList = @(ConvertTo-GhostNicTargetList -Value ([string]$configuredGroups))
    }
}

$excludedForRemoval = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$vmIdPattern = '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<vmName>[^/]+)$'
$recencyStateVariableName = 'GhostNicRecencyState'
$executionId = [guid]::NewGuid().ToString('D')

function ConvertTo-GhostNicStateTable {
    param($Value)

    $table = @{}
    if ($null -eq $Value) { return $table }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $table[[string]$key] = $Value[$key] }
        return $table
    }
    foreach ($property in $Value.PSObject.Properties) { $table[[string]$property.Name] = $property.Value }
    return $table
}

function Get-GhostNicRecencyState {
    $rawState = Get-AutomationVariable -Name $recencyStateVariableName -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$rawState)) { return @{} }
    return ConvertTo-GhostNicStateTable -Value ([string]$rawState | ConvertFrom-Json -ErrorAction Stop)
}

function Get-GhostNicStateValue {
    param($Entry, [Parameter(Mandatory)][string]$Name, $Default = $null)

    if ($null -eq $Entry) { return $Default }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return $Entry[$Name] }
        return $Default
    }
    $property = $Entry.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-GhostNicStateEntry {
    param($Entry)

    $copy = [ordered]@{}
    if ($null -eq $Entry) { return $copy }
    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($key in $Entry.Keys) { $copy[[string]$key] = $Entry[$key] }
    } else {
        foreach ($property in $Entry.PSObject.Properties) { $copy[[string]$property.Name] = $property.Value }
    }
    return $copy
}

function Set-GhostNicRecencyState {
    param([Parameter(Mandatory)][hashtable]$State)

    Set-AutomationVariable -Name $recencyStateVariableName -Value ($State | ConvertTo-Json -Depth 8 -Compress) -ErrorAction Stop
}

function Enter-GhostNicVmLease {
    param([Parameter(Mandatory)][string]$VmResourceId)

    try {
        $state = Get-GhostNicRecencyState
        $key = $VmResourceId.ToLowerInvariant()
        $entry = if ($state.ContainsKey($key)) { $state[$key] } else { $null }
        $now = [DateTimeOffset]::UtcNow
        $leaseUntilText = [string](Get-GhostNicStateValue -Entry $entry -Name 'LeaseUntilUtc' -Default '')
        $leaseOwner = [string](Get-GhostNicStateValue -Entry $entry -Name 'LeaseOwner' -Default '')
        $leaseUntil = [DateTimeOffset]::MinValue
        if ($leaseUntilText -and [DateTimeOffset]::TryParse($leaseUntilText, [ref]$leaseUntil) -and $leaseUntil -gt $now -and $leaseOwner -ne $executionId) {
            return [pscustomobject]@{ ShouldRun = $false; Reason = 'InProgress'; Entry = $entry; StateAvailable = $true }
        }

        if ([bool]$UseFreshnessFilter) {
            $lastCompletedText = [string](Get-GhostNicStateValue -Entry $entry -Name 'LastCompletedUtc' -Default '')
            $lastCompleted = [DateTimeOffset]::MinValue
            $maintenanceState = [string](Get-GhostNicStateValue -Entry $entry -Name 'MaintenanceState' -Default '')
            $recent = $lastCompletedText -and [DateTimeOffset]::TryParse($lastCompletedText, [ref]$lastCompleted) -and $lastCompleted -gt $now.AddHours(-[int]$FreshnessHours)
            $freshRemovalNeedsWork = $Operation -eq 'Remove' -and $maintenanceState -eq 'CleanupPending'
            if ($recent -and -not $freshRemovalNeedsWork) {
                return [pscustomobject]@{ ShouldRun = $false; Reason = 'Fresh'; Entry = $entry; StateAvailable = $true }
            }
        }

        $entryData = ConvertTo-GhostNicStateEntry -Entry $entry
        $entryData['LeaseOwner'] = $executionId
        $entryData['LeaseUntilUtc'] = $now.AddHours(6).ToString('o')
        $entryData['LastAttemptUtc'] = $now.ToString('o')
        $state[$key] = [pscustomobject]$entryData
        Set-GhostNicRecencyState -State $state

        # Re-read to make concurrent hourly/daily jobs converge on one lease owner.
        $verifiedState = Get-GhostNicRecencyState
        $verifiedEntry = if ($verifiedState.ContainsKey($key)) { $verifiedState[$key] } else { $null }
        if ([string](Get-GhostNicStateValue -Entry $verifiedEntry -Name 'LeaseOwner' -Default '') -ne $executionId) {
            return [pscustomobject]@{ ShouldRun = $false; Reason = 'InProgress'; Entry = $verifiedEntry; StateAvailable = $true }
        }
        return [pscustomobject]@{ ShouldRun = $true; Reason = 'Due'; Entry = $verifiedEntry; StateAvailable = $true }
    }
    catch {
        if ([bool]$UseFreshnessFilter) {
            return [pscustomobject]@{ ShouldRun = $false; Reason = 'StateUnavailable'; Entry = $null; StateAvailable = $false; Error = $_.Exception.Message }
        }
        return [pscustomobject]@{ ShouldRun = $true; Reason = 'StateUnavailable'; Entry = $null; StateAvailable = $false; Error = $_.Exception.Message }
    }
}

function Complete-GhostNicVmLease {
    param(
        [Parameter(Mandatory)][string]$VmResourceId,
        [Parameter(Mandatory)]$ResultRecord
    )

    try {
        $state = Get-GhostNicRecencyState
        $key = $VmResourceId.ToLowerInvariant()
        $entry = if ($state.ContainsKey($key)) { $state[$key] } else { $null }
        $entryData = ConvertTo-GhostNicStateEntry -Entry $entry
        $entryData['LastCompletedUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
        $entryData['DetectedAtUtc'] = [string]$ResultRecord.DetectedAtUtc
        $entryData['LastOperation'] = [string]$ResultRecord.Operation
        $entryData['MaintenanceState'] = [string]$ResultRecord.MaintenanceState
        $entryData['Outcome'] = [string]$ResultRecord.Outcome
        $entryData['GhostedCount'] = $ResultRecord.GhostedCount
        $entryData['ValidCount'] = $ResultRecord.ValidCount
        $entryData['RemovedCount'] = $ResultRecord.RemovedCount
        $entryData['RemainingCount'] = $ResultRecord.RemainingCount
        $entryData['RestartRequired'] = $ResultRecord.RestartRequired
        $entryData['LeaseOwner'] = ''
        $entryData['LeaseUntilUtc'] = ''
        $entryData['LastError'] = ''
        $state[$key] = [pscustomobject]$entryData
        Set-GhostNicRecencyState -State $state
    }
    catch {
        Write-Warning "Could not persist Ghost NIC recency state for '$VmResourceId': $($_.Exception.Message)"
    }
}

function Release-GhostNicVmLease {
    param([Parameter(Mandatory)][string]$VmResourceId, [string]$ErrorMessage = '')

    try {
        $state = Get-GhostNicRecencyState
        $key = $VmResourceId.ToLowerInvariant()
        if (-not $state.ContainsKey($key)) { return }
        $entryData = ConvertTo-GhostNicStateEntry -Entry $state[$key]
        if ([string](Get-GhostNicStateValue -Entry $state[$key] -Name 'LeaseOwner' -Default '') -eq $executionId) {
            $entryData['LeaseOwner'] = ''
            $entryData['LeaseUntilUtc'] = ''
        }
        $entryData['LastError'] = $ErrorMessage
        $state[$key] = [pscustomobject]$entryData
        Set-GhostNicRecencyState -State $state
    }
    catch {
        Write-Warning "Could not release Ghost NIC recency lease for '$VmResourceId': $($_.Exception.Message)"
    }
}
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptionSource = if ($targetVmResourceIdList.Count -gt 0) { $targetVmResourceIdList[0] } elseif ($targetResourceGroupIdList.Count -gt 0) { $targetResourceGroupIdList[0] } else { '' }
    $firstTargetSubscriptionMatch = [regex]::Match($subscriptionSource, '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $firstTargetSubscriptionMatch.Success) { throw "Cannot infer SubscriptionId from target: $subscriptionSource" }
    $SubscriptionId = $firstTargetSubscriptionMatch.Groups['subscriptionId'].Value
}

foreach ($groupId in $targetResourceGroupIdList) {
    $groupMatch = [regex]::Match($groupId, '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $groupMatch.Success) { throw "Target is not a full Azure resource-group ID: $groupId" }
}

Connect-AzAccount -Identity | Out-Null
$currentSubscriptionId = ''
function Set-GhostNicSubscriptionContext {
    param([Parameter(Mandatory)][string]$TargetSubscriptionId)

    if ($script:currentSubscriptionId -ne $TargetSubscriptionId) {
        Set-AzContext -SubscriptionId $TargetSubscriptionId | Out-Null
        $script:currentSubscriptionId = $TargetSubscriptionId
    }
}
Set-GhostNicSubscriptionContext -TargetSubscriptionId $SubscriptionId

if ($targetVmResourceIdList.Count -eq 0) {
    if ($targetResourceGroupIdList.Count -eq 0) {
        throw 'No targets were supplied. Pass TargetVmResourceIds, TargetResourceGroupIds, or configure target Automation variables.'
    }
    $targetVmResourceIdList = @(
        foreach ($groupId in $targetResourceGroupIdList) {
            $groupMatch = [regex]::Match($groupId, '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $groupMatch.Success) { throw "Target is not a full Azure resource-group ID: $groupId" }
            Set-GhostNicSubscriptionContext -TargetSubscriptionId $groupMatch.Groups['subscriptionId'].Value
            foreach ($vm in @(Get-AzVM -ResourceGroupName $groupMatch.Groups['resourceGroup'].Value -ErrorAction Stop)) {
                if ($vm.StorageProfile.OsDisk.OsType -ne 'Windows') { continue }
                $exclusion = if ($vm.Tags) { [string]$vm.Tags[$ExclusionTagName] } else { '' }
                $values = @($exclusion -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
                if (@($values | Where-Object { $_ -in $scanExclusions }).Count -gt 0) { continue }
                if ($Operation -eq 'Remove' -and @($values | Where-Object { $_ -in $removalExclusions }).Count -gt 0) { [void]$excludedForRemoval.Add($vm.Id) }
                $vm.Id
            }
        }
    )
}

$vmPowerStateById = @{}
function Get-GhostNicVmPowerState {
    param([Parameter(Mandatory)]$VmStatus)

    $powerStateProperty = $VmStatus.PSObject.Properties['PowerState']
    if ($powerStateProperty -and -not [string]::IsNullOrWhiteSpace([string]$powerStateProperty.Value)) {
        return [string]$powerStateProperty.Value
    }

    $statusesProperty = $VmStatus.PSObject.Properties['Statuses']
    if ($statusesProperty -and $null -ne $statusesProperty.Value) {
        $powerStatus = $statusesProperty.Value | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -Last 1
        if ($powerStatus) { return [string]$powerStatus.DisplayStatus }
    }

    return 'Unknown'
}

$targetGroupScopes = @(
    $targetVmResourceIdList |
        ForEach-Object {
            $targetMatch = [regex]::Match($_, $vmIdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $targetMatch.Success) { throw "Target is not a full Azure VM resource ID: $_" }
            [pscustomobject]@{
                SubscriptionId = $targetMatch.Groups['subscriptionId'].Value
                ResourceGroupName = $targetMatch.Groups['resourceGroup'].Value
            }
        } |
        Sort-Object SubscriptionId, ResourceGroupName -Unique
)
foreach ($targetGroupScope in $targetGroupScopes) {
    Set-GhostNicSubscriptionContext -TargetSubscriptionId $targetGroupScope.SubscriptionId
    foreach ($vmStatus in @(Get-AzVM -ResourceGroupName $targetGroupScope.ResourceGroupName -Status -ErrorAction Stop)) {
        $nameProperty = $vmStatus.PSObject.Properties['Name']
        if (-not $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) { continue }
        $vmPowerStateById["$($targetGroupScope.SubscriptionId)/$($targetGroupScope.ResourceGroupName)/$($nameProperty.Value)"] = Get-GhostNicVmPowerState -VmStatus $vmStatus
    }
}

$vmPowerStateByResourceId = @{}
$eligibleVmResourceIds = [System.Collections.Generic.List[string]]::new()
$deferredVmResourceIds = [System.Collections.Generic.List[string]]::new()
foreach ($vmResourceId in @($targetVmResourceIdList | Select-Object -Unique)) {
    $vmResourceIdMatch = [regex]::Match($vmResourceId, $vmIdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $vmResourceIdMatch.Success) { throw "Target is not a full Azure VM resource ID: $vmResourceId" }
    Set-GhostNicSubscriptionContext -TargetSubscriptionId $vmResourceIdMatch.Groups['subscriptionId'].Value
    $vm = Get-AzVM -ResourceId $vmResourceId -ErrorAction Stop
    $vmPowerStateKey = "$($vmResourceIdMatch.Groups['subscriptionId'].Value)/$($vm.ResourceGroupName)/$($vm.Name)"
    $powerState = if ($vmPowerStateById.ContainsKey($vmPowerStateKey)) { [string]$vmPowerStateById[$vmPowerStateKey] } else { 'Unknown' }
    $vmPowerStateByResourceId[$vmResourceId] = $powerState
    $exclusion = if ($vm.Tags) { [string]$vm.Tags[$ExclusionTagName] } else { '' }
    $values = @($exclusion -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if (@($values | Where-Object { $_ -in $scanExclusions }).Count -gt 0) {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $true; Outcome = 'Excluded'; MaintenanceState = 'Excluded'; ExclusionType = 'scan'; PowerState = $powerState; Operation = $Operation; CommandIssued = $false } |
            ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        continue
    }
    if ($Operation -eq 'Remove' -and @($values | Where-Object { $_ -in $removalExclusions }).Count -gt 0) { [void]$excludedForRemoval.Add($vmResourceId) }
    if ($excludedForRemoval.Contains($vmResourceId)) {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $true; Outcome = 'Excluded'; MaintenanceState = 'Excluded'; ExclusionType = 'remove'; PowerState = $powerState; Operation = $Operation; CommandIssued = $false } |
            ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        continue
    }
    if ($powerState -ne 'VM running') {
        [void]$deferredVmResourceIds.Add($vmResourceId)
        continue
    }
    [void]$eligibleVmResourceIds.Add($vmResourceId)
}
$targetVmResourceIdList = @($eligibleVmResourceIds)

$guestScript = @'
param(
    [Parameter(Mandatory)]
    [ValidateSet('Detect', 'Remove')]
    [string]$Operation,
    [string]$ConfirmRemoval = 'false',
    [int]$MaximumCandidateCount = 1000,
    [int]$PnpCleanWaitSeconds = 10,
    [string]$RequireProblemCode45 = 'true'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$confirmRemovalEnabled = [System.Convert]::ToBoolean($ConfirmRemoval)
$requireProblemCode45Enabled = [System.Convert]::ToBoolean($RequireProblemCode45)

if ($Operation -eq 'Remove' -and -not $confirmRemovalEnabled) {
    throw 'Removal confirmation was not supplied.'
}

$normalize = { param([string]$Id) if ($Id) { $Id.Trim().ToUpperInvariant() } }

function Get-ActiveAdapterSnapshot {
    @(
        Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.PnpDeviceID } |
            ForEach-Object {
                $interfaceGuid = if ($_.InterfaceGuid) { ([string]$_.InterfaceGuid).Trim('{}').ToUpperInvariant() } else { '' }
                $macAddress = if ($_.MacAddress) { ([string]$_.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() } else { '' }
                [pscustomobject]@{
                    Name          = [string]$_.Name
                    Status        = [string]$_.Status
                    PnpDeviceId   = $_.PnpDeviceID.Trim().ToUpperInvariant()
                    InterfaceGuid = $interfaceGuid
                    MacAddress    = $macAddress
                }
            }
    )
}

function Test-AdapterIdentityMatch {
    param(
        [Parameter(Mandatory)]$BaselineAdapter,
        [Parameter(Mandatory)]$CurrentAdapter
    )

    if ($BaselineAdapter.PnpDeviceId -eq $CurrentAdapter.PnpDeviceId) { return $true }
    if ($BaselineAdapter.InterfaceGuid -and
        $BaselineAdapter.InterfaceGuid -ne '00000000-0000-0000-0000-000000000000' -and
        $BaselineAdapter.InterfaceGuid -eq $CurrentAdapter.InterfaceGuid) { return $true }
    if ($BaselineAdapter.MacAddress -and
        $BaselineAdapter.MacAddress -notmatch '^0+$' -and
        $BaselineAdapter.MacAddress -eq $CurrentAdapter.MacAddress) { return $true }
    return $false
}

function Find-MatchingAdapter {
    param(
        [Parameter(Mandatory)]$BaselineAdapter,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CurrentAdapters
    )

    foreach ($currentAdapter in $CurrentAdapters) {
        if (Test-AdapterIdentityMatch -BaselineAdapter $BaselineAdapter -CurrentAdapter $currentAdapter) {
            return $currentAdapter
        }
    }
    return $null
}

function Get-MissingProtectedAdapters {
    param(
        [Parameter(Mandatory)][object[]]$ProtectedAdapters,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CurrentAdapters
    )

    foreach ($protectedAdapter in $ProtectedAdapters) {
        $matchingAdapter = Find-MatchingAdapter -BaselineAdapter $protectedAdapter -CurrentAdapters $CurrentAdapters
        if ($null -eq $matchingAdapter) {
            [pscustomobject]@{
                Name               = $protectedAdapter.Name
                BeforeStatus       = $protectedAdapter.Status
                BeforePnpDeviceId  = $protectedAdapter.PnpDeviceId
                InterfaceGuid      = $protectedAdapter.InterfaceGuid
                MacAddress         = $protectedAdapter.MacAddress
                ValidationFailure  = 'Missing'
                CurrentStatus      = ''
                CurrentPnpDeviceId = ''
            }
        } elseif ($protectedAdapter.Status -eq 'Up' -and $matchingAdapter.Status -ne 'Up') {
            [pscustomobject]@{
                Name               = $protectedAdapter.Name
                BeforeStatus       = $protectedAdapter.Status
                BeforePnpDeviceId  = $protectedAdapter.PnpDeviceId
                InterfaceGuid      = $protectedAdapter.InterfaceGuid
                MacAddress         = $protectedAdapter.MacAddress
                ValidationFailure  = 'NotUp'
                CurrentStatus      = $matchingAdapter.Status
                CurrentPnpDeviceId = $matchingAdapter.PnpDeviceId
            }
        }
    }
}

$activeAdapterSnapshot = @(Get-ActiveAdapterSnapshot)
$activePnpIds = @($activeAdapterSnapshot | ForEach-Object PnpDeviceId)
if ($activePnpIds.Count -eq 0) { throw 'SafetyAbort: no active network adapter PnP IDs were observed.' }
$protectedAdapterSnapshot = @($activeAdapterSnapshot | Where-Object Status -eq 'Up')
if ($protectedAdapterSnapshot.Count -eq 0) { $protectedAdapterSnapshot = @($activeAdapterSnapshot) }
$allNetworkPnpDevices = @(Get-PnpDevice -Class Net -ErrorAction Stop | Where-Object { $_.InstanceId })
$presentPnpIds = @(
    Get-PnpDevice -Class Net -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId } |
        ForEach-Object { $_.InstanceId.Trim().ToUpperInvariant() }
)
$ghosted = [System.Collections.Generic.List[object]]::new()
$valid = [System.Collections.Generic.List[object]]::new()
$candidateEntriesById = @{}

function Get-NicRegistryEntries {
    param([Parameter(Mandatory)][string]$BusName)

    $rootPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$BusName"
    if (-not (Test-Path -LiteralPath $rootPath)) { return }

    foreach ($vendorKey in Get-ChildItem -LiteralPath $rootPath -ErrorAction Stop) {
        foreach ($deviceKey in Get-ChildItem -LiteralPath $vendorKey.PSPath -ErrorAction Stop) {
            $properties = Get-ItemProperty -LiteralPath $deviceKey.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $properties) { continue }
            $serviceProperty = $properties.PSObject.Properties['Service']
            if (-not $serviceProperty -or $serviceProperty.Value -notin @('netvsc', 'mlx5', 'mlx4_bus')) { continue }

            $descriptionProperty = $properties.PSObject.Properties['DeviceDesc']
            $description = if ($descriptionProperty) { [string]$descriptionProperty.Value } else { '' }
            if ($description -and $description.Contains(';')) { $description = ($description -split ';', 2)[1] }
            if (-not $description) { $description = 'Unknown Device' }
            $instanceIndex = (Get-ItemProperty -LiteralPath (Join-Path $deviceKey.PSPath 'Device Parameters') -Name InstanceIndex -ErrorAction SilentlyContinue).InstanceIndex
            if ($instanceIndex -and $instanceIndex -ne 1) { $description = "$description #$instanceIndex" }

            [pscustomobject]@{
                RegistryPath = $deviceKey.PSPath
                PnpDeviceId  = $deviceKey.Name.Replace('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\', '')
                Service      = [string]$serviceProperty.Value
                Description  = $description
                ClassGuid    = if ($properties.PSObject.Properties['ClassGuid']) { [string]$properties.PSObject.Properties['ClassGuid'].Value } else { '' }
            }
        }
    }
}

function Add-NicCandidateEntry {
    param([Parameter(Mandatory)]$Entry)

    $normalizedId = & $normalize $Entry.PnpDeviceId
    if (-not $normalizedId -or $candidateEntriesById.ContainsKey($normalizedId)) { return }
    $candidateEntriesById[$normalizedId] = $Entry
}

foreach ($bus in @('PCI', 'VMBUS')) {
    foreach ($entry in @(Get-NicRegistryEntries -BusName $bus)) {
        if ($entry.ClassGuid -and $entry.ClassGuid -ine '{4d36e972-e325-11ce-bfc1-08002be10318}') { continue }
        Add-NicCandidateEntry -Entry $entry
    }
}

# Microsoft separately recommends a full Mellanox PnP inventory because stale device
# nodes are not always represented by the two registry buses above. Include every
# Network-class Mellanox node and every node using a targeted Azure NIC service.
foreach ($pnpDevice in $allNetworkPnpDevices) {
    $serviceProperty = Get-PnpDeviceProperty -InstanceId $pnpDevice.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue
    $service = if ($serviceProperty) { [string]$serviceProperty.Data } else { '' }
    $friendlyName = if ($pnpDevice.FriendlyName) { [string]$pnpDevice.FriendlyName } else { 'Unknown Device' }
    if ($service -notin @('netvsc', 'mlx5', 'mlx4_bus') -and $friendlyName -notlike '*Mellanox*') { continue }
    Add-NicCandidateEntry -Entry ([pscustomobject]@{
            RegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($pnpDevice.InstanceId)"
            PnpDeviceId = [string]$pnpDevice.InstanceId
            Service = $service
            Description = $friendlyName
            ClassGuid = '{4d36e972-e325-11ce-bfc1-08002be10318}'
            DiscoverySource = 'PnpInventory'
        })
}

foreach ($entry in $candidateEntriesById.Values) {
    $normalizedId = & $normalize $entry.PnpDeviceId
    if ($activePnpIds -contains $normalizedId) {
        $valid.Add($entry)
        continue
    }

    $pnp = Get-PnpDevice -InstanceId $entry.PnpDeviceId -ErrorAction SilentlyContinue
    $problemCode = $null
    if ($pnp) {
        $problemProperty = $pnp.PSObject.Properties['Problem']
        if ($problemProperty -and $null -ne $problemProperty.Value) {
            $problemCode = [int]$problemProperty.Value
        }
    }
    $ghosted.Add([pscustomobject]@{
            Entry = $entry
            Pnp = $pnp
            PnpDeviceId = $entry.PnpDeviceId
            ProblemCode = $problemCode
            IsPresent = ($presentPnpIds -contains $normalizedId)
        })
}

$outcome = if ($ghosted.Count -eq 0) { 'Clean' } else { 'Detected' }
$exitCode = if ($ghosted.Count -eq 0) { 0 } else { 2 }
$deviceResults = [System.Collections.Generic.List[object]]::new()
$pnpCleanExitCode = $null
$adapterValidation = 'NotRun'
$adapterValidationAttempts = 0
$finalAdapterSnapshot = @($activeAdapterSnapshot)
$missingActiveAdapters = @()
$addedActiveAdapters = @()
$reenumeratedActiveAdapters = @()
if ($ghosted.Count -gt $MaximumCandidateCount) {
    $outcome = 'SafetyAbort'; $exitCode = 4
} elseif ($Operation -eq 'Remove' -and $ghosted.Count -gt 0) {
    $pnpCleanProcess = Start-Process `
        -FilePath "$env:WINDIR\System32\rundll32.exe" `
        -ArgumentList @("$env:WINDIR\System32\pnpclean.dll,RunDLL_PnpClean", '/Devices', '/Maxclean') `
        -WindowStyle Hidden `
        -Wait `
        -PassThru `
        -ErrorAction Stop
    $pnpCleanExitCode = [int]$pnpCleanProcess.ExitCode
    Start-Sleep -Seconds $PnpCleanWaitSeconds
    foreach ($candidate in $ghosted) {
        $method = 'PnpClean'
        $nativeExitCode = $pnpCleanExitCode
        $registryFallbackUsed = $false
        $removalAuthorizedForCandidate = (-not $requireProblemCode45Enabled -or $candidate.ProblemCode -eq 45 -or -not $candidate.IsPresent)
        if (Get-PnpDevice -InstanceId $candidate.PnpDeviceId -ErrorAction SilentlyContinue) {
            if ($removalAuthorizedForCandidate) {
                $method = 'pnputil'
                $pnputilProcess = Start-Process `
                    -FilePath "$env:WINDIR\System32\pnputil.exe" `
                    -ArgumentList @('/remove-device', $candidate.PnpDeviceId) `
                    -WindowStyle Hidden `
                    -Wait `
                    -PassThru `
                    -ErrorAction Stop
                $nativeExitCode = [int]$pnputilProcess.ExitCode
            } else { $method = 'Ambiguous'; $nativeExitCode = 4 }
        }

        # Run Command executes as LocalSystem. Match Microsoft's cleanup behavior by
        # removing a leftover candidate key only after the active-adapter exclusion and
        # optional problem-code gate have both passed.
        $registryPath = [string]$candidate.Entry.RegistryPath
        if ($removalAuthorizedForCandidate -and $registryPath -and (Test-Path -LiteralPath $registryPath)) {
            try {
                Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction Stop
                $registryFallbackUsed = $true
                $method = "$method+Registry"
            }
            catch {
                $method = "$method+RegistryFailed"
                if ($nativeExitCode -eq 0) { $nativeExitCode = 5 }
            }
        }

        $deviceResults.Add([pscustomobject]@{
                PnpDeviceId = $candidate.PnpDeviceId
                Service = $candidate.Entry.Service
                FriendlyName = $candidate.Entry.Description
                ProblemCode = $candidate.ProblemCode
                WasPresent = [bool]$candidate.IsPresent
                Method = $method
                NativeExitCode = $nativeExitCode
                RegistryFallbackUsed = $registryFallbackUsed
                RegistryPath = $registryPath
                FinalState = 'PendingVerification'
            })
    }

    $scanProcess = Start-Process `
        -FilePath "$env:WINDIR\System32\pnputil.exe" `
        -ArgumentList @('/scan-devices') `
        -WindowStyle Hidden `
        -Wait `
        -PassThru `
        -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    foreach ($deviceResult in $deviceResults) {
        $pnpStillExists = $null -ne (Get-PnpDevice -InstanceId $deviceResult.PnpDeviceId -ErrorAction SilentlyContinue)
        $registryStillExists = $deviceResult.RegistryPath -and (Test-Path -LiteralPath $deviceResult.RegistryPath)
        $deviceResult.FinalState = if (-not $pnpStillExists -and -not $registryStillExists) { 'Removed' } else { 'Present' }
    }
    $remaining = @($deviceResults | Where-Object FinalState -ne 'Removed')

    # PnpClean can briefly re-enumerate an otherwise healthy Azure NIC. Retry the
    # snapshot and match stable adapter identity before declaring collateral loss.
    $adapterValidationMaxAttempts = 6
    $adapterValidationRetrySeconds = 5
    for ($adapterValidationAttempt = 1; $adapterValidationAttempt -le $adapterValidationMaxAttempts; $adapterValidationAttempt++) {
        $adapterValidationAttempts = $adapterValidationAttempt
        $finalAdapterSnapshot = @(Get-ActiveAdapterSnapshot)
        $missingActiveAdapters = @(Get-MissingProtectedAdapters -ProtectedAdapters $protectedAdapterSnapshot -CurrentAdapters $finalAdapterSnapshot)
        if ($missingActiveAdapters.Count -eq 0) { break }
        if ($adapterValidationAttempt -lt $adapterValidationMaxAttempts) {
            Start-Sleep -Seconds $adapterValidationRetrySeconds
        }
    }

    $addedActiveAdapters = @(
        foreach ($currentAdapter in $finalAdapterSnapshot) {
            if ($null -eq (Find-MatchingAdapter -BaselineAdapter $currentAdapter -CurrentAdapters $activeAdapterSnapshot)) {
                $currentAdapter
            }
        }
    )
    $reenumeratedActiveAdapters = @(
        foreach ($baselineAdapter in $activeAdapterSnapshot) {
            $currentAdapter = Find-MatchingAdapter -BaselineAdapter $baselineAdapter -CurrentAdapters $finalAdapterSnapshot
            if ($null -ne $currentAdapter -and $baselineAdapter.PnpDeviceId -ne $currentAdapter.PnpDeviceId) {
                $identityMatch = if ($baselineAdapter.InterfaceGuid -and $baselineAdapter.InterfaceGuid -ne '00000000-0000-0000-0000-000000000000' -and $baselineAdapter.InterfaceGuid -eq $currentAdapter.InterfaceGuid) { 'InterfaceGuid' } else { 'MacAddress' }
                [pscustomobject]@{
                    Name              = $baselineAdapter.Name
                    BeforePnpDeviceId = $baselineAdapter.PnpDeviceId
                    AfterPnpDeviceId  = $currentAdapter.PnpDeviceId
                    IdentityMatch     = $identityMatch
                }
            }
        }
    )

    if ($missingActiveAdapters.Count -gt 0) {
        $adapterValidation = 'Failed'
        $outcome = 'SafetyAbort'; $exitCode = 4
    } else {
        $adapterValidation = if ($reenumeratedActiveAdapters.Count -gt 0 -or $addedActiveAdapters.Count -gt 0) { 'PassedWithChanges' } else { 'Passed' }
    }
    if ($exitCode -ne 4 -and $remaining.Count -gt 0) { $outcome = 'PartialFailure'; $exitCode = 3 }
    elseif ($exitCode -ne 4) { $outcome = 'Remediated'; $exitCode = 0 }
}

[pscustomobject]@{
    SchemaVersion   = '2.0'
    Operation       = $Operation
    ComputerName    = $env:COMPUTERNAME
    DetectedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    Outcome         = $outcome
    ExitCode        = $exitCode
    GhostedCount    = $ghosted.Count
    ValidCount      = $valid.Count
    RemovedCount    = @($deviceResults | Where-Object FinalState -eq 'Removed').Count
    RemainingCount  = if ($Operation -eq 'Remove' -and $deviceResults.Count -gt 0) { @($deviceResults | Where-Object FinalState -ne 'Removed').Count } else { $ghosted.Count }
    RestartRequired = (@($deviceResults | Where-Object FinalState -eq 'Removed').Count -gt 0)
    PnpCleanExitCode = $pnpCleanExitCode
    ActiveAdapterValidation = $adapterValidation
    ActiveAdapterValidationAttempts = $adapterValidationAttempts
    MissingActiveAdapters = @($missingActiveAdapters)
    AddedActiveAdapters = @($addedActiveAdapters | Select-Object Name, Status, PnpDeviceId, InterfaceGuid, MacAddress)
    ReenumeratedActiveAdapters = @($reenumeratedActiveAdapters)
    RemovalMethods = @($deviceResults | Group-Object Method | ForEach-Object { [pscustomobject]@{ Method = $_.Name; Count = $_.Count } })
    RemainingDeviceIds = @($deviceResults | Where-Object FinalState -ne 'Removed' | Select-Object -First 20 -ExpandProperty PnpDeviceId)
    DiscoveryCount = $candidateEntriesById.Count
    GhostDeviceExamples = @($ghosted | Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{
                PnpDeviceId = $_.PnpDeviceId
                FriendlyName = $_.Entry.Description
                Service = $_.Entry.Service
                ProblemCode = $_.ProblemCode
                IsPresent = [bool]$_.IsPresent
            }
        })
} | ConvertTo-Json -Depth 8 -Compress | ForEach-Object { "GHNIC_GUEST_RESULT:$PSItem" }
'@

function Invoke-GhostNicTarget {
    param(
        [Parameter(Mandatory)][string]$VmResourceId,
        [Parameter(Mandatory)][string]$CurrentPowerState,
        [Parameter(Mandatory)][int]$RetryAttempt
    )

    $match = [regex]::Match($vmResourceId, $vmIdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Target is not a full Azure VM resource ID: $vmResourceId"
    }

    $lease = Enter-GhostNicVmLease -VmResourceId $VmResourceId
    if (-not $lease.ShouldRun) {
        $priorState = [string](Get-GhostNicStateValue -Entry $lease.Entry -Name 'MaintenanceState' -Default '')
        $skipState = if ($lease.Reason -eq 'StateUnavailable') { 'AttentionRequired' } elseif ($priorState) { $priorState } else { 'InProgress' }
        $skipOutcome = switch ($lease.Reason) {
            'Fresh' { 'FreshnessSkipped' }
            'InProgress' { 'InProgressSkipped' }
            default { 'RecencyStateUnavailable' }
        }
        [pscustomobject]@{
            SchemaVersion = '1.0'
            VmResourceId = $VmResourceId
            Succeeded = ($lease.Reason -ne 'StateUnavailable')
            Operation = $Operation
            PowerState = $CurrentPowerState
            DetectedAtUtc = [string](Get-GhostNicStateValue -Entry $lease.Entry -Name 'DetectedAtUtc' -Default '')
            GhostedCount = Get-GhostNicStateValue -Entry $lease.Entry -Name 'GhostedCount'
            ValidCount = Get-GhostNicStateValue -Entry $lease.Entry -Name 'ValidCount'
            RemovedCount = Get-GhostNicStateValue -Entry $lease.Entry -Name 'RemovedCount'
            RemainingCount = Get-GhostNicStateValue -Entry $lease.Entry -Name 'RemainingCount'
            Outcome = $skipOutcome
            MaintenanceState = $skipState
            RestartRequired = [bool](Get-GhostNicStateValue -Entry $lease.Entry -Name 'RestartRequired' -Default $false)
            CommandIssued = $false
            FreshnessHours = if ([bool]$UseFreshnessFilter) { [int]$FreshnessHours } else { $null }
            LastCompletedUtc = [string](Get-GhostNicStateValue -Entry $lease.Entry -Name 'LastCompletedUtc' -Default '')
            Error = if ($lease.PSObject.Properties['Error']) { [string]$lease.Error } else { '' }
        } | ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        return
    }

    try {
        Set-GhostNicSubscriptionContext -TargetSubscriptionId $match.Groups['subscriptionId'].Value
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $match.Groups['resourceGroup'].Value `
            -Name $match.Groups['vmName'].Value `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $guestScript `
            -Parameter @{ Operation = $Operation; ConfirmRemoval = ([bool]$ConfirmRemoval).ToString().ToLowerInvariant(); MaximumCandidateCount = [int]$MaximumCandidateCount; PnpCleanWaitSeconds = [int]$PnpCleanWaitSeconds; RequireProblemCode45 = ([bool]$RequireProblemCode45).ToString().ToLowerInvariant() } `
            -ErrorAction Stop

        $guestMessage = (@($result.Value | ForEach-Object Message) -join "`n")
        $guestMatch = [regex]::Match($guestMessage, '(?m)^GHNIC_GUEST_RESULT:(?<json>\{.*\})\s*$')
        if (-not $guestMatch.Success) {
            $guestDiagnostic = ($guestMessage -replace '\s+', ' ').Trim()
            if ($guestDiagnostic.Length -gt 2000) { $guestDiagnostic = $guestDiagnostic.Substring(0, 2000) }
            if ([string]::IsNullOrWhiteSpace($guestDiagnostic)) { $guestDiagnostic = 'Run Command returned no stdout or stderr.' }
            throw "VM Run Command completed without a parseable Ghost NIC Hunter guest result. Guest output: $guestDiagnostic"
        }
        $guestResult = $guestMatch.Groups['json'].Value | ConvertFrom-Json -ErrorAction Stop
        $restartIssued = $false
        $restartError = ''
        if ($Operation -eq 'Remove' -and [bool]$RestartRemediatedVm -and [int]$guestResult.ExitCode -eq 0 -and [string]$guestResult.Outcome -eq 'Remediated' -and [bool]$guestResult.RestartRequired -and [int]$guestResult.RemovedCount -gt 0) {
            try {
                Restart-AzVM `
                    -ResourceGroupName $match.Groups['resourceGroup'].Value `
                    -Name $match.Groups['vmName'].Value `
                    -Force `
                    -NoWait `
                    -ErrorAction Stop | Out-Null
                $restartIssued = $true
            }
            catch {
                $restartError = $_.Exception.Message
            }
        }

        $maintenanceState = if ($restartError) {
            'RebootFailed'
        } elseif ($restartIssued) {
            'RestartInitiated'
        } elseif ([string]$guestResult.Outcome -in @('SafetyAbort', 'PartialFailure')) {
            'AttentionRequired'
        } elseif ($Operation -eq 'Remove' -and [int]$guestResult.RemovedCount -gt 0 -and [bool]$guestResult.RestartRequired) {
            'RebootPending'
        } elseif ([int]$guestResult.GhostedCount -gt 0) {
            'CleanupPending'
        } else {
            'VerifiedClean'
        }
        $resultRecord = [pscustomobject]@{
            SchemaVersion = '1.0'
            VmResourceId = $vmResourceId
            Succeeded    = ([int]$guestResult.ExitCode -in @(0, 2) -and -not $restartError)
            Operation    = $Operation
            PowerState   = $CurrentPowerState
            DetectedAtUtc = $guestResult.DetectedAtUtc
            GhostedCount = [int]$guestResult.GhostedCount
            ValidCount = [int]$guestResult.ValidCount
            RemovedCount = [int]$guestResult.RemovedCount
            RemainingCount = [int]$guestResult.RemainingCount
            Outcome = if ($restartError) { 'RestartFailed' } else { [string]$guestResult.Outcome }
            MaintenanceState = $maintenanceState
            ExitCode = if ($restartError) { 5 } else { [int]$guestResult.ExitCode }
            RestartRequired = [bool]$guestResult.RestartRequired
            RestartIssued = $restartIssued
            RestartError = $restartError
            RetryAttempt = $RetryAttempt
            ActiveAdapterValidation = [string]$guestResult.ActiveAdapterValidation
            ActiveAdapterValidationAttempts = [int]$guestResult.ActiveAdapterValidationAttempts
            MissingActiveAdapters = @($guestResult.MissingActiveAdapters)
            AddedActiveAdapters = @($guestResult.AddedActiveAdapters)
            ReenumeratedActiveAdapters = @($guestResult.ReenumeratedActiveAdapters)
            RemovalMethods = @($guestResult.RemovalMethods)
            RemainingDeviceIds = @($guestResult.RemainingDeviceIds)
            DiscoveryCount = [int]$guestResult.DiscoveryCount
            GhostDeviceExamples = @($guestResult.GhostDeviceExamples)
        }
        Complete-GhostNicVmLease -VmResourceId $VmResourceId -ResultRecord $resultRecord
        $resultRecord | ConvertTo-Json -Depth 8 -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
    } catch {
        Release-GhostNicVmLease -VmResourceId $VmResourceId -ErrorMessage $_.Exception.Message
        [pscustomobject]@{
            SchemaVersion = '1.0'
            VmResourceId = $vmResourceId
            Succeeded    = $false
            Operation    = $Operation
            PowerState   = $CurrentPowerState
            Outcome      = 'RunCommandFailed'
            MaintenanceState = 'AttentionRequired'
            RetryAttempt = $RetryAttempt
            Error        = $_.Exception.Message
        } | ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
    }
}

foreach ($vmResourceId in $targetVmResourceIdList) {
    $currentPowerState = if ($vmPowerStateByResourceId.ContainsKey($vmResourceId)) { [string]$vmPowerStateByResourceId[$vmResourceId] } else { 'Unknown' }
    Invoke-GhostNicTarget -VmResourceId $vmResourceId -CurrentPowerState $currentPowerState -RetryAttempt 0
}

$remainingOfflineVmResourceIds = @($deferredVmResourceIds)
for ($retryAttempt = 1; $retryAttempt -le $OfflineRetryCount -and $remainingOfflineVmResourceIds.Count -gt 0; $retryAttempt++) {
    if ($OfflineRetryDelayMinutes -gt 0) { Start-Sleep -Seconds ([int]$OfflineRetryDelayMinutes * 60) }
    $stillOfflineVmResourceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($vmResourceId in $remainingOfflineVmResourceIds) {
        $match = [regex]::Match($vmResourceId, $vmIdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        Set-GhostNicSubscriptionContext -TargetSubscriptionId $match.Groups['subscriptionId'].Value
        $vmStatus = Get-AzVM -ResourceId $vmResourceId -Status -ErrorAction Stop
        $currentPowerState = Get-GhostNicVmPowerState -VmStatus $vmStatus
        $vmPowerStateByResourceId[$vmResourceId] = $currentPowerState
        if ($currentPowerState -eq 'VM running') {
            Invoke-GhostNicTarget -VmResourceId $vmResourceId -CurrentPowerState $currentPowerState -RetryAttempt $retryAttempt
        } else {
            [void]$stillOfflineVmResourceIds.Add($vmResourceId)
        }
    }
    $remainingOfflineVmResourceIds = @($stillOfflineVmResourceIds)
}

foreach ($vmResourceId in $remainingOfflineVmResourceIds) {
    $currentPowerState = if ($vmPowerStateByResourceId.ContainsKey($vmResourceId)) { [string]$vmPowerStateByResourceId[$vmResourceId] } else { 'Unknown' }
    [pscustomobject]@{
        SchemaVersion = '1.0'
        VmResourceId = $vmResourceId
        Succeeded = $false
        Outcome = 'OfflineSkipped'
        MaintenanceState = 'OfflineSkipped'
        PowerState = $currentPowerState
        Operation = $Operation
        CommandIssued = $false
        RetryAttempts = [int]$OfflineRetryCount
    } | ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
}
