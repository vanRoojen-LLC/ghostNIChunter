# Ghost NIC Hunter operations

## Preflight

1. Confirm the VM is Windows, has the Azure VM agent in a healthy state, and is not currently executing another Run Command.
2. Confirm the VM uses Accelerated Networking or exhibits the symptoms Microsoft associates with ghosted NICs. This utility only targets the service types used by Microsoft’s sample: `netvsc`, `mlx5`, and `mlx4_bus`.
3. Run a `Detect` job and retain its output with the incident or maintenance record.
4. Before a `Remove` job, create or verify a recovery point/snapshot according to the VM’s existing backup policy. The tool cannot undo registry/device removal.

## Azure portal deployment

The repository’s **Deploy to Azure** button opens the Azure portal template wizard. It creates the Automation account in the selected resource group, imports the published runbooks, and grants that account’s managed identity **Virtual Machine Contributor** on each target resource group whose full resource ID you enter. Selected groups can span subscriptions in the same tenant when the deploying identity can create role assignments at every scope. The selected groups become the `GhostNicTargetResourceGroupIds` Automation variable, and the runbook switches subscription context for discovery and Run Command.

The portal deployment does not issue a Run Command or remove anything. It requires the deploying user to have role-assignment write permission on every target resource group. Add or remove target groups through the deployment workflow so the stored scope and Azure RBAC are handled together. The deployment grants selected scopes but does not revoke role assignments left on a group that is removed from the list; remove obsolete assignments explicitly.

The **Encrypt Automation Variables** choice defaults to `true`. Keep it enabled for the normal policy-compliant deployment. Choosing `false` keeps the seven app variables readable in the portal, but a policy assignment using `Deny` for unencrypted Automation variables rejects that deployment. Encryption mode is immutable after a variable is created; changing the deployment choice alone cannot convert an existing installation.

## Azure authority model

The Automation account uses a system-assigned managed identity. It needs **Virtual Machine Contributor** (or a custom role that includes `Microsoft.Compute/virtualMachines/runCommand/write`) at each selected target resource-group scope. Do not grant it subscription-wide authority merely to cover multiple groups.

`Configure-GhostNicHunter` uses Azure Automation's internal variable cmdlets and does not need another managed-identity role. Restrict permission to start that runbook to administrators who are allowed to change application behavior.

## Persistent behavior settings

The templates create seven Automation variables: `GhostNicTargetResourceGroupIds` plus these six persistent behavior settings:

| Variable | Default |
|---|---:|
| `GhostNicMaximumCandidateCount` | `1000` |
| `GhostNicExclusionTagName` | `ghostNicHunterExclusions` |
| `GhostNicScanExclusionValues` | `scan,all` |
| `GhostNicRemovalExclusionValues` | `remove,all` |
| `GhostNicPnpCleanWaitSeconds` | `10` |
| `GhostNicRequireProblemCode45` | `true` |

Use `Configure-GhostNicHunter` to validate one or more behavior changes. It works the same way with encrypted or normal variables. A job without `ApplyChanges=$true` is a dry run; its output reports only changed variable names and counts, never values.

```powershell
$config = @{
  MaximumCandidateCount = 500
  PnpCleanWaitSeconds = 20
  RequireProblemCode45 = $true
  ApplyChanges = $true
}
Start-AzAutomationRunbook `
  -ResourceGroupName '<automation-rg>' `
  -AutomationAccountName '<automation-account>' `
  -Name 'Configure-GhostNicHunter' `
  -Parameters $config
```

Target resource groups are intentionally outside this configuration runbook because changing scope also requires granting or revoking Azure RBAC. Use the portal wizard or `Deploy-GhostNicHunter.ps1` for scope changes. A template redeployment resets the six persistent behavior settings to their defaults, so run `Configure-GhostNicHunter` again afterward to restore intended custom values.

`Operation` and `ConfirmRemoval` are not Automation variables. They are per-job safety gates: an omitted operation always becomes `Detect`, and removal requires both `Operation=Remove` and `ConfirmRemoval=$true` on that individual job. The daily schedule also passes `Operation=Detect` explicitly.

## Variable encryption migration

Azure Automation cannot change a variable's encryption mode in place. First record any customized values for the six behavior settings in the approved change record because the required redeployment resets them to defaults. Then use `deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1` before redeploying with `EncryptAutomationVariables=$true`. The helper refuses every nonterminal Automation job, pauses an enabled daily schedule, holds only normal values in process memory, removes obsolete `GhostNicOperation`, `GhostNicConfirmRemoval`, and persistent `GhostNicTargetVmResourceIds` assets, recreates the seven current variables encrypted, and verifies their state before restoring the schedule. It can resume a mixed state left by an interrupted migration by converting only the remaining normal variables. It never prints values and leaves the schedule disabled if migration fails.

Review WhatIf before applying the migration:

```powershell
./deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName '<automation-account>' `
  -ConfirmMigration `
  -WhatIf

./deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName '<automation-account>' `
  -ConfirmMigration
```

After migration, redeploy with encryption enabled and immediately reapply the recorded behavior settings through `Configure-GhostNicHunter`. If a failed attempt disabled the schedule, verify the successful retry and re-enable the schedule manually. The helper refuses unsupported variables and only migrates toward encrypted storage. External PowerShell cannot retrieve an encrypted value, so reversing to normal variables requires deleting and recreating them with complete replacement values. A strict `Deny` policy will reject those normal replacements.

## Target discovery and exclusions

The runbook can discover Windows VMs from the `GhostNicTargetResourceGroupIds` Automation variable. On each VM, the `ghostNicHunterExclusions` tag accepts comma- or semicolon-separated values: `scan` skips detection and removal, `remove` permits detection but blocks removal, and `scan,remove` (or `all`) blocks both. Exclusions are re-read immediately before Run Command is issued.

The person or pipeline running `Deploy-GhostNicHunter.ps1` needs permission to deploy `Microsoft.Automation/automationAccounts` and create role assignments at every selected target group. Use `-EncryptAutomationVariables $true` for encrypted variables or `$false` only where readable variables are intentional and policy permits them. The deployed runbooks do not retain operator credentials or a secret.

## Expected result format

Each VM produces a compact, prefixed JSON output record: `GHNIC_RESULT:{...}`. A structured guest result has `GhostedCount`, `ValidCount`, `RemovedCount`, `PowerState`, `Operation`, `RestartRequired`, and active-adapter validation details even when final validation fails. An orchestration or unparseable guest failure has `Succeeded:false`, the most recently observed `PowerState`, and an error. This stable marker is what the optional workbook parses from `AzureDiagnostics` JobStreams.

When removal completes, `RestartRequired` is reported as true when it deleted registry paths. Schedule the reboot through the VM’s normal change process; Ghost NIC Hunter never restarts a VM itself.

## Dashboard semantics

With `LogAnalyticsWorkspaceResourceId` set during deployment, diagnostic settings forward JobLogs and JobStreams to the selected existing workspace and deploy the Azure Monitor workbook. The dashboard shows:

- **Current top offenders** — the most recent successful scan for every VM, sorted by current ghost count, merged with power state from Azure Resource Graph at workbook refresh time.
- **Cumulative offenders** — each VM’s total ghost observations and scans with ghosts, retaining VMs that are now clean so recurrence remains visible, plus refresh-time Resource Graph power state.
- **Efficacy** — removal job count, ghost NICs presented to removal, ghost NICs reported removed, safety-abort count, and a weekly removal trend.

Cumulative ghost observations are not deduplicated devices; scanning an uncleared VM again adds another observation by design. `VM status` is the Resource Graph value at workbook refresh, while `Last-run status` is the state recorded by Automation and remains available when the live lookup has no match. The scan data still depends on Azure Monitor log delivery, so new detection results can take a few minutes to appear after a completed Automation job.

## Failure handling

- A malformed resource ID or a subscription the Automation identity cannot access fails before Run Command. Valid target IDs can span accessible subscriptions in the same tenant.
- In the portal Start pane, enter `TargetVmResourceIds` as one resource ID, a comma/semicolon/newline-separated string, or a JSON string array. The runbook intentionally exposes this as a string so a single ID cannot fail Azure Automation parameter binding before the job starts.
- A target without Run Command permission, a stopped/deallocated VM, or an unhealthy VM agent produces a per-VM failure record; it does not make the runbook silently succeed.
- A removal without both explicit confirmation values is rejected before any VM command is sent.
- A no-parameter maintenance job always uses `Detect`; removal mode and confirmation cannot be persisted.
- After removal, the guest retries adapter validation up to six times at five-second intervals. It matches adapters by normalized PnP ID, interface GUID, or MAC address so ordinary PnP re-enumeration does not create a false abort. `MissingActiveAdapters`, `AddedActiveAdapters`, and `ReenumeratedActiveAdapters` identify any observed change; only a previously up adapter that remains missing or not up produces `SafetyAbort`.
- If the cleanup fails partway through, use the VM recovery point/change record and investigate with Microsoft support guidance; do not rerun removal blindly.
