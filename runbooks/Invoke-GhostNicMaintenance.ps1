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

    [ValidateSet('Detect', 'Remove')]
    [string]$Operation = 'Detect',

    [bool]$ConfirmRemoval = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Operation -eq 'Remove' -and -not $ConfirmRemoval) {
    throw 'Removal is blocked. Set both Operation=Remove and ConfirmRemoval=$true after reviewing a detection job and confirming a VM recovery point.'
}

if (-not $TargetVmResourceIds -or $TargetVmResourceIds.Count -eq 0) {
    $configuredTargets = Get-AutomationVariable -Name 'GhostNicTargetVmResourceIds' -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($configuredTargets)) {
        throw 'No targets were supplied. Pass TargetVmResourceIds or configure the GhostNicTargetVmResourceIds Automation variable.'
    }
    $TargetVmResourceIds = @(
        $configuredTargets -split '[,;\r\n]+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $firstTargetSubscriptionMatch = [regex]::Match($TargetVmResourceIds[0], '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $firstTargetSubscriptionMatch.Success) {
        throw "Cannot infer SubscriptionId from target: $($TargetVmResourceIds[0])"
    }
    $SubscriptionId = $firstTargetSubscriptionMatch.Groups['subscriptionId'].Value
}

Connect-AzAccount -Identity | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$guestScript = @'
param(
    [Parameter(Mandatory)]
    [ValidateSet('Detect', 'Remove')]
    [string]$Operation,
    [bool]$ConfirmRemoval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Operation -eq 'Remove' -and -not $ConfirmRemoval) {
    throw 'Removal confirmation was not supplied.'
}

$activePnpIds = @(Get-NetAdapter -ErrorAction Stop | ForEach-Object PnpDeviceID | Where-Object { $_ })
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
            }
        }
    }
}

foreach ($bus in @('PCI', 'VMBUS')) {
    foreach ($entry in @(Get-NicRegistryEntries -BusName $bus)) {
        if ($activePnpIds -contains $entry.PnpDeviceId) {
            $valid.Add($entry)
        } else {
            $ghosted.Add($entry)
        }
    }
}

$removedPaths = [System.Collections.Generic.List[string]]::new()
if ($Operation -eq 'Remove' -and $ghosted.Count -gt 0) {
    & "$env:WINDIR\System32\rundll32.exe" "$env:WINDIR\System32\pnpclean.dll,RunDLL_PnpClean" '/Devices' '/Maxclean'
    Start-Sleep -Seconds 10

    foreach ($entry in $ghosted) {
        if (Test-Path -LiteralPath $entry.RegistryPath) {
            Remove-Item -LiteralPath $entry.RegistryPath -Recurse -Force -ErrorAction Stop
            $removedPaths.Add($entry.RegistryPath)
        }
    }
}

[pscustomobject]@{
    Operation       = $Operation
    ComputerName    = $env:COMPUTERNAME
    DetectedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    GhostedCount    = $ghosted.Count
    ValidCount      = $valid.Count
    GhostedNic      = @($ghosted)
    RemovedPaths    = @($removedPaths)
    RestartRequired = ($removedPaths.Count -gt 0)
} | ConvertTo-Json -Depth 6 -Compress | ForEach-Object { "GHNIC_GUEST_RESULT:$PSItem" }
'@

$vmIdPattern = '^/subscriptions/(?<subscriptionId>[0-9a-fA-F-]{36})/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<vmName>[^/]+)$'
foreach ($vmResourceId in $TargetVmResourceIds) {
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
            -Parameter @{ Operation = $Operation; ConfirmRemoval = $ConfirmRemoval } `
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
            Succeeded    = $true
            Operation    = $Operation
            DetectedAtUtc = $guestResult.DetectedAtUtc
            GhostedCount = [int]$guestResult.GhostedCount
            ValidCount = [int]$guestResult.ValidCount
            RemovedCount = @($guestResult.RemovedPaths).Count
            RestartRequired = [bool]$guestResult.RestartRequired
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
