<#
.SYNOPSIS
Validates and updates persistent Ghost NIC Hunter behavior settings.

.DESCRIPTION
Runs inside Azure Automation and updates only the six whitelisted behavior variables.
It works with either encrypted or normal variables because Set-AutomationVariable uses the
existing asset's storage mode. Target scope and removal authorization are intentionally not
configurable here: target changes require matching Azure RBAC changes, and every removal job
must explicitly pass Operation=Remove and ConfirmRemoval=$true.
#>
[CmdletBinding()]
param(
    [Nullable[int]]$MaximumCandidateCount,

    [string]$ExclusionTagName,

    [string]$ScanExclusionValues,

    [string]$RemovalExclusionValues,

    [Nullable[int]]$PnpCleanWaitSeconds,

    [Nullable[bool]]$RequireProblemCode45,

    [bool]$ApplyChanges = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parameterToVariable = [ordered]@{
    MaximumCandidateCount = 'GhostNicMaximumCandidateCount'
    ExclusionTagName = 'GhostNicExclusionTagName'
    ScanExclusionValues = 'GhostNicScanExclusionValues'
    RemovalExclusionValues = 'GhostNicRemovalExclusionValues'
    PnpCleanWaitSeconds = 'GhostNicPnpCleanWaitSeconds'
    RequireProblemCode45 = 'GhostNicRequireProblemCode45'
}

$requestedParameters = @(
    $parameterToVariable.Keys |
        Where-Object { $PSBoundParameters.ContainsKey($_) }
)

if ($requestedParameters.Count -eq 0) {
    throw 'No behavior settings were supplied. Specify at least one setting; target scope must be changed through the deployment workflow.'
}

$updates = [ordered]@{}

if ($PSBoundParameters.ContainsKey('MaximumCandidateCount')) {
    if ($MaximumCandidateCount -lt 1 -or $MaximumCandidateCount -gt 10000) {
        throw 'MaximumCandidateCount must be between 1 and 10000.'
    }
    $updates['GhostNicMaximumCandidateCount'] = [int]$MaximumCandidateCount
}

if ($PSBoundParameters.ContainsKey('ExclusionTagName')) {
    $normalizedTagName = $ExclusionTagName.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedTagName) -or $normalizedTagName.Length -gt 512) {
        throw 'ExclusionTagName must contain between 1 and 512 characters.'
    }
    if ($normalizedTagName -match '[,;]') {
        throw 'ExclusionTagName cannot contain commas or semicolons.'
    }
    $updates['GhostNicExclusionTagName'] = $normalizedTagName
}

foreach ($definition in @(
        @{ Parameter = 'ScanExclusionValues'; Variable = 'GhostNicScanExclusionValues'; Value = $ScanExclusionValues }
        @{ Parameter = 'RemovalExclusionValues'; Variable = 'GhostNicRemovalExclusionValues'; Value = $RemovalExclusionValues }
    )) {
    if (-not $PSBoundParameters.ContainsKey($definition.Parameter)) { continue }

    $normalizedValues = @(
        [string]$definition.Value -split '[,;]+' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    if ($normalizedValues.Count -eq 0) {
        throw "$($definition.Parameter) must contain at least one comma- or semicolon-separated value."
    }
    $updates[$definition.Variable] = $normalizedValues -join ','
}

if ($PSBoundParameters.ContainsKey('PnpCleanWaitSeconds')) {
    if ($PnpCleanWaitSeconds -lt 0 -or $PnpCleanWaitSeconds -gt 300) {
        throw 'PnpCleanWaitSeconds must be between 0 and 300.'
    }
    $updates['GhostNicPnpCleanWaitSeconds'] = [int]$PnpCleanWaitSeconds
}

if ($PSBoundParameters.ContainsKey('RequireProblemCode45')) {
    $updates['GhostNicRequireProblemCode45'] = [bool]$RequireProblemCode45
}

$updatedVariables = @()
if ($ApplyChanges) {
    try {
        foreach ($entry in $updates.GetEnumerator()) {
            Set-AutomationVariable -Name $entry.Key -Value $entry.Value | Out-Null
            $updatedVariables += $entry.Key
        }
    }
    catch {
        $updatedSummary = if ($updatedVariables.Count -gt 0) { ($updatedVariables | Sort-Object) -join ', ' } else { 'none' }
        throw "Configuration update failed. Variables updated before failure: $updatedSummary. No setting values were written to output; review the Automation job and activity logs for the underlying platform error."
    }
}

$result = [ordered]@{
    Succeeded = $true
    Applied = [bool]$ApplyChanges
    RequestedCount = $updates.Count
    RequestedVariables = @($updates.Keys)
    UpdatedCount = $updatedVariables.Count
    UpdatedVariables = @($updatedVariables)
    RemovalSafety = 'Operation and ConfirmRemoval remain explicit per-job parameters.'
    TargetScope = 'Change target resource groups through the deployment workflow so Azure RBAC is updated with scope.'
}

Write-Output "GHNIC_CONFIG:$($result | ConvertTo-Json -Depth 4 -Compress)"
