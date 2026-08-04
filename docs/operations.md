# Ghost NIC Hunter operations

## Preflight

1. Confirm the VM is Windows, has the Azure VM agent in a healthy state, and is not currently executing another Run Command.
2. Confirm the VM uses Accelerated Networking or exhibits the symptoms Microsoft associates with ghosted NICs. This utility only targets the service types used by Microsoft’s sample: `netvsc`, `mlx5`, and `mlx4_bus`.
3. Run a `Detect` job and retain its output with the incident or maintenance record.
4. Before a `Remove` job, create or verify a recovery point/snapshot according to the VM’s existing backup policy. The tool cannot undo registry/device removal.

## Azure portal deployment

The repository’s **Deploy to Azure** button opens the Azure portal template wizard. It creates the Automation account in the selected resource group, imports the published runbook, and grants that account’s managed identity **Virtual Machine Contributor** on the one VM whose full resource ID you enter. That same VM ID becomes the default `GhostNicTargetVmResourceIds` Automation variable, so a first detection job can be started with no parameters.

The portal deployment does not issue a Run Command or remove anything. It requires the deploying user to have role-assignment write permission on the target VM. Add other target VMs deliberately: assign the Automation identity the same role at each VM scope, then append their resource IDs to the variable.

## Azure authority model

The Automation account uses a system-assigned managed identity. It needs **Virtual Machine Contributor** (or a custom role that includes `Microsoft.Compute/virtualMachines/runCommand/write`) at each selected target resource-group scope. Do not grant it subscription-wide authority merely to cover multiple groups.

## Target discovery and exclusions

The runbook can discover Windows VMs from the `GhostNicTargetResourceGroupIds` Automation variable. On each VM, the `ghostNicHunterExclusions` tag accepts comma- or semicolon-separated values: `scan` skips detection and removal, `remove` permits detection but blocks removal, and `scan,remove` (or `all`) blocks both. Exclusions are re-read immediately before Run Command is issued.

The person or pipeline running `Deploy-GhostNicHunter.ps1` needs permission to deploy `Microsoft.Automation/automationAccounts` and, when `TargetScope` is set, to create the role assignment. The deployed runbook does not retain operator credentials or a secret.

## Expected result format

Each VM produces a compact, prefixed JSON output record: `GHNIC_RESULT:{...}`. A successful record has `GhostedCount`, `ValidCount`, `RemovedCount`, `PowerState`, `Operation`, and `RestartRequired`; a failure record has `Succeeded:false`, the most recently observed `PowerState`, and an error. This stable marker is what the optional workbook parses from `AzureDiagnostics` JobStreams.

When removal completes, `RestartRequired` is reported as true when it deleted registry paths. Schedule the reboot through the VM’s normal change process; Ghost NIC Hunter never restarts a VM itself.

## Dashboard semantics

With `LogAnalyticsWorkspaceResourceId` set during deployment, diagnostic settings forward JobLogs and JobStreams to the selected existing workspace and deploy the Azure Monitor workbook. The dashboard shows:

- **Current top offenders** — the most recent successful scan for every VM, sorted by current ghost count, merged with power state from Azure Resource Graph at workbook refresh time.
- **Cumulative offenders** — each VM’s total ghost observations and scans with ghosts, retaining VMs that are now clean so recurrence remains visible, plus refresh-time Resource Graph power state.
- **Efficacy** — removal job count, ghost NICs presented to removal, registry paths actually removed, and a weekly removal trend.

Cumulative ghost observations are not deduplicated devices; scanning an uncleared VM again adds another observation by design. `VM status` is the Resource Graph value at workbook refresh, while `Last-run status` is the state recorded by Automation and remains available when the live lookup has no match. The scan data still depends on Azure Monitor log delivery, so new detection results can take a few minutes to appear after a completed Automation job.

## Failure handling

- A bad resource ID or a target in a different subscription fails before execution.
- In the portal Start pane, enter `TargetVmResourceIds` as one resource ID, a comma/semicolon/newline-separated string, or a JSON string array. The runbook intentionally exposes this as a string so a single ID cannot fail Azure Automation parameter binding before the job starts.
- A target without Run Command permission, a stopped/deallocated VM, or an unhealthy VM agent produces a per-VM failure record; it does not make the runbook silently succeed.
- A removal without both explicit confirmation values is rejected before any VM command is sent.
- If the cleanup fails partway through, use the VM recovery point/change record and investigate with Microsoft support guidance; do not rerun removal blindly.
