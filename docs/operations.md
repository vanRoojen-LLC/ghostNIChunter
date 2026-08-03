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

The Automation account uses a system-assigned managed identity. It needs **Virtual Machine Contributor** (or a custom role that includes `Microsoft.Compute/virtualMachines/runCommand/write`) at the exact VM or resource-group scope it will service. Do not grant it subscription-wide authority unless that scope is intentional.

The person or pipeline running `Deploy-GhostNicHunter.ps1` needs permission to deploy `Microsoft.Automation/automationAccounts` and, when `TargetScope` is set, to create the role assignment. The deployed runbook does not retain operator credentials or a secret.

## Expected result format

Each VM produces a compact, prefixed JSON output record: `GHNIC_RESULT:{...}`. A successful record has `GhostedCount`, `ValidCount`, `RemovedCount`, `Operation`, and `RestartRequired`; a failure record has `Succeeded:false` and an error. This stable marker is what the optional workbook parses from `AzureDiagnostics` JobStreams.

When removal completes, `RestartRequired` is reported as true when it deleted registry paths. Schedule the reboot through the VM’s normal change process; Ghost NIC Hunter never restarts a VM itself.

## Dashboard semantics

With `LogAnalyticsWorkspaceResourceId` set during deployment, diagnostic settings forward JobLogs and JobStreams to the selected existing workspace and deploy the Azure Monitor workbook. The dashboard shows:

- **Current top offenders** — the most recent successful scan for every VM, sorted by current ghost count.
- **Cumulative offenders** — each VM’s total ghost observations and scans with ghosts, retaining VMs that are now clean so recurrence remains visible.
- **Efficacy** — removal job count, ghost NICs presented to removal, registry paths actually removed, and a weekly removal trend.

Cumulative ghost observations are not deduplicated devices; scanning an uncleared VM again adds another observation by design. The workbook’s source is Azure Monitor log delivery, so its initial data can take a few minutes to appear after a completed Automation job.

## Failure handling

- A bad resource ID or a target in a different subscription fails before execution.
- A target without Run Command permission, a stopped/deallocated VM, or an unhealthy VM agent produces a per-VM failure record; it does not make the runbook silently succeed.
- A removal without both explicit confirmation values is rejected before any VM command is sent.
- If the cleanup fails partway through, use the VM recovery point/change record and investigate with Microsoft support guidance; do not rerun removal blindly.
