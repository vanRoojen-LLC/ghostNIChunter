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

    [ValidateNotNullOrEmpty()]
    [string[]]$TargetVmResourceIds,

    [ValidateNotNullOrEmpty()]
    [string[]]$TargetResourceGroupIds,

    [string]$Operation = '',

    [Nullable[bool]]$ConfirmRemoval,

    [Nullable[int]]$MaximumCandidateCount,

    [string]$ExclusionTagName = '',
    [string]$ScanExclusionValues = '',
    [string]$RemovalExclusionValues = '',
    [Nullable[int]]$PnpCleanWaitSeconds,
    [Nullable[bool]]$RequireProblemCode45
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

if ([string]::IsNullOrWhiteSpace($Operation)) { $Operation = [string](Get-GhostNicAutomationVariable 'GhostNicOperation' 'Detect') }
if ($Operation -notin @('Detect', 'Remove')) { throw "Invalid GhostNicOperation '$Operation'. Use Detect or Remove." }
if ($null -eq $ConfirmRemoval) { $ConfirmRemoval = [System.Convert]::ToBoolean((Get-GhostNicAutomationVariable 'GhostNicConfirmRemoval' $false)) }
if ($null -eq $MaximumCandidateCount) { $MaximumCandidateCount = [int](Get-GhostNicAutomationVariable 'GhostNicMaximumCandidateCount' 1000) }
if ($MaximumCandidateCount -lt 1 -or $MaximumCandidateCount -gt 10000) { throw 'GhostNicMaximumCandidateCount must be between 1 and 10000.' }
if ([string]::IsNullOrWhiteSpace($ExclusionTagName)) { $ExclusionTagName = [string](Get-GhostNicAutomationVariable 'GhostNicExclusionTagName' 'ghostNicHunterExclusions') }
if ([string]::IsNullOrWhiteSpace($ScanExclusionValues)) { $ScanExclusionValues = [string](Get-GhostNicAutomationVariable 'GhostNicScanExclusionValues' 'scan,all') }
if ([string]::IsNullOrWhiteSpace($RemovalExclusionValues)) { $RemovalExclusionValues = [string](Get-GhostNicAutomationVariable 'GhostNicRemovalExclusionValues' 'remove,all') }
if ($null -eq $PnpCleanWaitSeconds) { $PnpCleanWaitSeconds = [int](Get-GhostNicAutomationVariable 'GhostNicPnpCleanWaitSeconds' 10) }
if ($PnpCleanWaitSeconds -lt 0 -or $PnpCleanWaitSeconds -gt 300) { throw 'GhostNicPnpCleanWaitSeconds must be between 0 and 300.' }
if ($null -eq $RequireProblemCode45) { $RequireProblemCode45 = [System.Convert]::ToBoolean((Get-GhostNicAutomationVariable 'GhostNicRequireProblemCode45' $true)) }
$scanExclusions = @($ScanExclusionValues -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$removalExclusions = @($RemovalExclusionValues -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })

if ($Operation -eq 'Remove' -and -not $ConfirmRemoval) {
    throw 'Removal is blocked. Set both Operation=Remove and ConfirmRemoval=$true after reviewing a detection job and confirming a VM recovery point.'
}

if (-not $TargetVmResourceIds -or $TargetVmResourceIds.Count -eq 0) {
    $configuredTargets = Get-AutomationVariable -Name 'GhostNicTargetVmResourceIds' -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($configuredTargets)) {
        $TargetVmResourceIds = @($configuredTargets -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

if (-not $TargetResourceGroupIds -or $TargetResourceGroupIds.Count -eq 0) {
    $configuredGroups = Get-AutomationVariable -Name 'GhostNicTargetResourceGroupIds' -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($configuredGroups)) {
        $TargetResourceGroupIds = @($configuredGroups -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

$excludedForRemoval = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$vmIdPattern = '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<vmName>[^/]+)$'
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptionSource = if ($TargetVmResourceIds) { $TargetVmResourceIds[0] } elseif ($TargetResourceGroupIds) { $TargetResourceGroupIds[0] } else { '' }
    $firstTargetSubscriptionMatch = [regex]::Match($subscriptionSource, '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $firstTargetSubscriptionMatch.Success) { throw "Cannot infer SubscriptionId from target: $subscriptionSource" }
    $SubscriptionId = $firstTargetSubscriptionMatch.Groups['subscriptionId'].Value
}
Connect-AzAccount -Identity | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

if (-not $TargetVmResourceIds -or $TargetVmResourceIds.Count -eq 0) {
    if (-not $TargetResourceGroupIds -or $TargetResourceGroupIds.Count -eq 0) {
        throw 'No targets were supplied. Pass TargetVmResourceIds, TargetResourceGroupIds, or configure target Automation variables.'
    }
    $TargetVmResourceIds = @(
        foreach ($groupId in $TargetResourceGroupIds) {
            $groupMatch = [regex]::Match($groupId, '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $groupMatch.Success) { throw "Target is not a full Azure resource-group ID: $groupId" }
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

$targetGroupNames = @(
    $TargetVmResourceIds |
        ForEach-Object {
            $targetMatch = [regex]::Match($_, $vmIdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($targetMatch.Success) { $targetMatch.Groups['resourceGroup'].Value }
        } |
        Select-Object -Unique
)
foreach ($targetGroupName in $targetGroupNames) {
    foreach ($vmStatus in @(Get-AzVM -ResourceGroupName $targetGroupName -Status -ErrorAction Stop)) {
        $nameProperty = $vmStatus.PSObject.Properties['Name']
        if (-not $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) { continue }
        $vmPowerStateById["$targetGroupName/$($nameProperty.Value)"] = Get-GhostNicVmPowerState -VmStatus $vmStatus
    }
}

$vmPowerStateByResourceId = @{}
$eligibleVmResourceIds = [System.Collections.Generic.List[string]]::new()
foreach ($vmResourceId in @($TargetVmResourceIds | Select-Object -Unique)) {
    $vm = Get-AzVM -ResourceId $vmResourceId -ErrorAction Stop
    $vmPowerStateKey = "$($vm.ResourceGroupName)/$($vm.Name)"
    $powerState = if ($vmPowerStateById.ContainsKey($vmPowerStateKey)) { [string]$vmPowerStateById[$vmPowerStateKey] } else { 'Unknown' }
    $vmPowerStateByResourceId[$vmResourceId] = $powerState
    $exclusion = if ($vm.Tags) { [string]$vm.Tags[$ExclusionTagName] } else { '' }
    $values = @($exclusion -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if (@($values | Where-Object { $_ -in $scanExclusions }).Count -gt 0) {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $true; Outcome = 'Excluded'; ExclusionType = 'scan'; PowerState = $powerState; Operation = $Operation; CommandIssued = $false } |
            ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        continue
    }
    if ($Operation -eq 'Remove' -and @($values | Where-Object { $_ -in $removalExclusions }).Count -gt 0) { [void]$excludedForRemoval.Add($vmResourceId) }
    if ($powerState -ne 'VM running') {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $false; Outcome = 'OfflineSkipped'; PowerState = $powerState; Operation = $Operation; CommandIssued = $false } |
            ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        continue
    }
    [void]$eligibleVmResourceIds.Add($vmResourceId)
}
$TargetVmResourceIds = @($eligibleVmResourceIds)

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
$activePnpIds = @(
    Get-NetAdapter -ErrorAction Stop |
        Where-Object { $_.PnpDeviceID } |
        ForEach-Object { $_.PnpDeviceID.Trim().ToUpperInvariant() }
)
if ($activePnpIds.Count -eq 0) { throw 'SafetyAbort: no active network adapter PnP IDs were observed.' }
$presentPnpIds = @(
    Get-PnpDevice -Class Net -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId } |
        ForEach-Object { $_.InstanceId.Trim().ToUpperInvariant() }
)
$ghosted = [System.Collections.Generic.List[object]]::new()
$valid = [System.Collections.Generic.List[object]]::new()

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

foreach ($bus in @('PCI', 'VMBUS')) {
    foreach ($entry in @(Get-NicRegistryEntries -BusName $bus)) {
        $normalizedId = & $normalize $entry.PnpDeviceId
        if ($entry.ClassGuid -ne '{4d36e972-e325-11ce-bfc1-08002be10318}' -or $activePnpIds -contains $normalizedId -or $presentPnpIds -contains $normalizedId) {
            $valid.Add($entry)
        } else {
            $pnp = Get-PnpDevice -InstanceId $entry.PnpDeviceId -ErrorAction SilentlyContinue
            $problemCode = $null
            if ($pnp) {
                $problemProperty = $pnp.PSObject.Properties['Problem']
                if ($problemProperty -and $null -ne $problemProperty.Value) {
                    $problemCode = [int]$problemProperty.Value
                }
            }
            $ghosted.Add([pscustomobject]@{ Entry = $entry; Pnp = $pnp; PnpDeviceId = $entry.PnpDeviceId; ProblemCode = $problemCode })
        }
    }
}

$outcome = if ($ghosted.Count -eq 0) { 'Clean' } else { 'Detected' }
$exitCode = if ($ghosted.Count -eq 0) { 0 } else { 2 }
$deviceResults = [System.Collections.Generic.List[object]]::new()
$pnpCleanExitCode = $null
if ($ghosted.Count -gt $MaximumCandidateCount) {
    $outcome = 'SafetyAbort'; $exitCode = 4
} elseif ($Operation -eq 'Remove' -and $ghosted.Count -gt 0) {
    & "$env:WINDIR\System32\rundll32.exe" "$env:WINDIR\System32\pnpclean.dll,RunDLL_PnpClean" '/Devices' '/Maxclean'
    $pnpCleanExitCode = $LASTEXITCODE
    Start-Sleep -Seconds $PnpCleanWaitSeconds
    foreach ($candidate in $ghosted) {
        $method = 'PnpClean'; $nativeExitCode = $pnpCleanExitCode; $finalState = 'Present'
        if (Get-PnpDevice -InstanceId $candidate.PnpDeviceId -ErrorAction SilentlyContinue) {
            if (-not $requireProblemCode45Enabled -or $candidate.ProblemCode -eq 45) {
                $method = 'pnputil'
                & "$env:WINDIR\System32\pnputil.exe" /remove-device $candidate.PnpDeviceId | Out-Null
                $nativeExitCode = $LASTEXITCODE
            } else { $method = 'Ambiguous'; $nativeExitCode = 4 }
        }
        if (-not (Get-PnpDevice -InstanceId $candidate.PnpDeviceId -ErrorAction SilentlyContinue)) { $finalState = 'Removed' }
        $deviceResults.Add([pscustomobject]@{ PnpDeviceId=$candidate.PnpDeviceId; Service=$candidate.Entry.Service; FriendlyName=$candidate.Entry.Description; ProblemCode=$candidate.ProblemCode; Method=$method; NativeExitCode=$nativeExitCode; FinalState=$finalState })
    }
    $remaining = @($deviceResults | Where-Object FinalState -ne 'Removed')
    $finalActive = @(
        Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.PnpDeviceID } |
            ForEach-Object { $_.PnpDeviceID.Trim().ToUpperInvariant() }
    )
    if (($activePnpIds | Sort-Object) -join ',' -ne ($finalActive | Sort-Object) -join ',') { $outcome = 'SafetyAbort'; $exitCode = 4 }
    elseif ($remaining.Count -gt 0) { $outcome = 'PartialFailure'; $exitCode = 3 }
    else { $outcome = 'Remediated'; $exitCode = 0 }
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
    RestartRequired = $false
    PnpCleanExitCode = $pnpCleanExitCode
} | ConvertTo-Json -Depth 8 -Compress | ForEach-Object { "GHNIC_GUEST_RESULT:$PSItem" }
'@

foreach ($vmResourceId in $TargetVmResourceIds) {
    $currentPowerState = if ($vmPowerStateByResourceId.ContainsKey($vmResourceId)) { [string]$vmPowerStateByResourceId[$vmResourceId] } else { 'Unknown' }
    if ($excludedForRemoval.Contains($vmResourceId)) {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $true; Outcome = 'Excluded'; ExclusionType = 'remove'; PowerState = $currentPowerState; Operation = $Operation; CommandIssued = $false } |
            ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        continue
    }
    $match = [regex]::Match($vmResourceId, $vmIdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Target is not a full Azure VM resource ID: $vmResourceId"
    }
    if ($match.Groups['subscriptionId'].Value -ne $SubscriptionId) {
        throw "Target subscription does not match SubscriptionId: $vmResourceId"
    }

    try {
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
        [pscustomobject]@{
            SchemaVersion = '1.0'
            VmResourceId = $vmResourceId
            Succeeded    = ([int]$guestResult.ExitCode -in @(0, 2))
            Operation    = $Operation
            PowerState   = $currentPowerState
            DetectedAtUtc = $guestResult.DetectedAtUtc
            GhostedCount = [int]$guestResult.GhostedCount
            ValidCount = [int]$guestResult.ValidCount
            RemovedCount = [int]$guestResult.RemovedCount
            Outcome = [string]$guestResult.Outcome
            ExitCode = [int]$guestResult.ExitCode
            RestartRequired = $false
        } | ConvertTo-Json -Depth 5 -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
    } catch {
        [pscustomobject]@{
            SchemaVersion = '1.0'
            VmResourceId = $vmResourceId
            Succeeded    = $false
            Operation    = $Operation
            PowerState   = $currentPowerState
            Error        = $_.Exception.Message
        } | ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
    }
}
