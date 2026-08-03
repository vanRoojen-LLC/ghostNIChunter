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

    [ValidateSet('Detect', 'Remove')]
    [string]$Operation = 'Detect',

    [bool]$ConfirmRemoval = $false,

    [ValidateRange(1, 10000)]
    [int]$MaximumCandidateCount = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
                $exclusion = if ($vm.Tags) { [string]$vm.Tags['ghostNicHunterExclusions'] } else { '' }
                $values = @($exclusion -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
                if ($values -contains 'scan' -or $values -contains 'all') { continue }
                if ($Operation -eq 'Remove' -and ($values -contains 'remove' -or $values -contains 'all')) { [void]$excludedForRemoval.Add($vm.Id) }
                $vm.Id
            }
        }
    )
}

$eligibleVmResourceIds = [System.Collections.Generic.List[string]]::new()
foreach ($vmResourceId in @($TargetVmResourceIds | Select-Object -Unique)) {
    $vm = Get-AzVM -ResourceId $vmResourceId -ErrorAction Stop
    $exclusion = if ($vm.Tags) { [string]$vm.Tags['ghostNicHunterExclusions'] } else { '' }
    $values = @($exclusion -split '[,;]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($values -contains 'scan' -or $values -contains 'all') {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $true; Outcome = 'Excluded'; ExclusionType = 'scan'; Operation = $Operation; CommandIssued = $false } |
            ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
        continue
    }
    if ($Operation -eq 'Remove' -and ($values -contains 'remove' -or $values -contains 'all')) { [void]$excludedForRemoval.Add($vmResourceId) }
    [void]$eligibleVmResourceIds.Add($vmResourceId)
}
$TargetVmResourceIds = @($eligibleVmResourceIds)

$guestScript = @'
param(
    [Parameter(Mandatory)]
    [ValidateSet('Detect', 'Remove')]
    [string]$Operation,
    [bool]$ConfirmRemoval,
    [int]$MaximumCandidateCount = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Operation -eq 'Remove' -and -not $ConfirmRemoval) {
    throw 'Removal confirmation was not supplied.'
}

$normalize = { param([string]$Id) if ($Id) { $Id.Trim().ToUpperInvariant() } }
$activePnpIds = @(Get-NetAdapter -ErrorAction Stop | ForEach-Object PnpDeviceID | ForEach-Object $normalize | Where-Object { $_ })
if ($activePnpIds.Count -eq 0) { throw 'SafetyAbort: no active network adapter PnP IDs were observed.' }
$presentPnpIds = @(Get-PnpDevice -Class Net -PresentOnly -ErrorAction Stop | ForEach-Object InstanceId | ForEach-Object $normalize | Where-Object { $_ })
$ghosted = [System.Collections.Generic.List[object]]::new()
$valid = [System.Collections.Generic.List[object]]::new()

function Get-NicRegistryEntries {
    param([Parameter(Mandatory)][string]$BusName)

    $rootPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$BusName"
    if (-not (Test-Path -LiteralPath $rootPath)) { return }

    foreach ($vendorKey in Get-ChildItem -LiteralPath $rootPath -ErrorAction Stop) {
        foreach ($deviceKey in Get-ChildItem -LiteralPath $vendorKey.PSPath -ErrorAction Stop) {
            $properties = Get-ItemProperty -LiteralPath $deviceKey.PSPath -ErrorAction SilentlyContinue
            if ($properties.Service -notin @('netvsc', 'mlx5', 'mlx4_bus')) { continue }

            $description = $properties.DeviceDesc
            if ($description -and $description.Contains(';')) { $description = ($description -split ';', 2)[1] }
            if (-not $description) { $description = 'Unknown Device' }
            $instanceIndex = (Get-ItemProperty -LiteralPath (Join-Path $deviceKey.PSPath 'Device Parameters') -Name InstanceIndex -ErrorAction SilentlyContinue).InstanceIndex
            if ($instanceIndex -and $instanceIndex -ne 1) { $description = "$description #$instanceIndex" }

            [pscustomobject]@{
                RegistryPath = $deviceKey.PSPath
                PnpDeviceId  = $deviceKey.Name.Replace('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\', '')
                Service      = $properties.Service
                Description  = $description
                ClassGuid    = [string]$properties.ClassGuid
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
            $ghosted.Add([pscustomobject]@{ Entry = $entry; Pnp = $pnp; PnpDeviceId = $entry.PnpDeviceId; ProblemCode = if ($pnp) { [int]$pnp.ConfigManagerErrorCode } else { $null } })
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
    Start-Sleep -Seconds 10
    foreach ($candidate in $ghosted) {
        $method = 'PnpClean'; $nativeExitCode = $pnpCleanExitCode; $finalState = 'Present'
        if (Get-PnpDevice -InstanceId $candidate.PnpDeviceId -ErrorAction SilentlyContinue) {
            if ($candidate.ProblemCode -eq 45) {
                $method = 'pnputil'
                & "$env:WINDIR\System32\pnputil.exe" /remove-device $candidate.PnpDeviceId | Out-Null
                $nativeExitCode = $LASTEXITCODE
            } else { $method = 'Ambiguous'; $nativeExitCode = 4 }
        }
        if (-not (Get-PnpDevice -InstanceId $candidate.PnpDeviceId -ErrorAction SilentlyContinue)) { $finalState = 'Removed' }
        $deviceResults.Add([pscustomobject]@{ PnpDeviceId=$candidate.PnpDeviceId; Service=$candidate.Entry.Service; FriendlyName=$candidate.Entry.Description; ProblemCode=$candidate.ProblemCode; Method=$method; NativeExitCode=$nativeExitCode; FinalState=$finalState })
    }
    $remaining = @($deviceResults | Where-Object FinalState -ne 'Removed')
    $finalActive = @(Get-NetAdapter -ErrorAction Stop | ForEach-Object PnpDeviceID | ForEach-Object $normalize | Where-Object { $_ })
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
    GhostedNic      = @($ghosted | ForEach-Object Entry)
    DeviceResults   = @($deviceResults)
    RestartRequired = $false
    PnpCleanExitCode = $pnpCleanExitCode
} | ConvertTo-Json -Depth 8 -Compress | ForEach-Object { "GHNIC_GUEST_RESULT:$PSItem" }
'@

$vmIdPattern = '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<vmName>[^/]+)$'
foreach ($vmResourceId in $TargetVmResourceIds) {
    if ($excludedForRemoval.Contains($vmResourceId)) {
        [pscustomobject]@{ SchemaVersion = '1.0'; VmResourceId = $vmResourceId; Succeeded = $true; Outcome = 'Excluded'; ExclusionType = 'remove'; Operation = $Operation; CommandIssued = $false } |
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
            -Parameter @{ Operation = $Operation; ConfirmRemoval = $ConfirmRemoval; MaximumCandidateCount = $MaximumCandidateCount } `
            -ErrorAction Stop

        $guestMessage = (@($result.Value | ForEach-Object Message) -join "`n")
        $guestMatch = [regex]::Match($guestMessage, '(?m)^GHNIC_GUEST_RESULT:(?<json>\{.*\})\s*$')
        if (-not $guestMatch.Success) {
            throw 'VM Run Command completed without a parseable Ghost NIC Hunter guest result.'
        }
        $guestResult = $guestMatch.Groups['json'].Value | ConvertFrom-Json -ErrorAction Stop
        [pscustomobject]@{
            SchemaVersion = '1.0'
            VmResourceId = $vmResourceId
            Succeeded    = ([int]$guestResult.ExitCode -eq 0)
            Operation    = $Operation
            DetectedAtUtc = $guestResult.DetectedAtUtc
            GhostedCount = [int]$guestResult.GhostedCount
            ValidCount = [int]$guestResult.ValidCount
            RemovedCount = @($guestResult.DeviceResults | Where-Object FinalState -eq 'Removed').Count
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
            Error        = $_.Exception.Message
        } | ConvertTo-Json -Compress | ForEach-Object { "GHNIC_RESULT:$PSItem" } | Write-Output
    }
}
