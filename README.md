# Ghost NIC Hunter

Ghost NIC Hunter is a small vanRoojen LLC Azure utility for detecting and, only with an explicit second confirmation, removing stale Windows network-device entries caused by Azure Accelerated Networking after a VM is deallocated and allocated again.

It deploys an Azure Automation account with a system-assigned managed identity and publishes one PowerShell runbook: `Invoke-GhostNicMaintenance`. The runbook uses Azure VM Run Command, so it does not require a Hybrid Runbook Worker or credentials stored in Automation.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FvanRoojen-LLC%2FghostNIChunter%2Fmain%2Fdeploy%2Fazuredeploy-20260803-4.json)
[![Deploy to Azure Gov](deploy/deploytoazuregov.svg)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FvanRoojen-LLC%2FghostNIChunter%2Fmain%2Fdeploy%2Fazuredeploy-20260803-4.json)

## What it does

- **Detect** (the default) inventories active and ghosted `netvsc`, `mlx5`, and `mlx4_bus` NIC entries on one or more Azure Windows VMs.
- **Remove** runs the same inventory, invokes Windows `pnpclean`, then removes only the registry entries classified as ghosted. It requires both `Operation=Remove` and `ConfirmRemoval=$true`.
- Emits one structured JSON result per VM, as well as the captured Run Command output.

Microsoft describes this as a design behavior of Accelerated Networking after deallocation/reallocation; it recommends checking first and making cleanup regular maintenance when appropriate. It also advises a recovery point before removal. See [the Microsoft troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-vm-ghostednic-troubleshooting).

## Deploy

### Deploy to Azure portal wizard

Click **Deploy to Azure** above. Azure Portal will ask you to sign in, select the subscription and resource group, and enter one target resource-group ID or multiple IDs separated by commas. The wizard automatically generates the Automation account and a dedicated Log Analytics workspace, imports the runbook, deploys the workbook, and grants its managed identity **Virtual Machine Contributor** on each selected target group.

The deploying identity needs permission to create the Automation account, workspace, workbook, and resource-group role assignments. The portal deployment does not run remediation; start the imported runbook with its safe `Detect` default after it completes.

For another VM, add its resource ID to the `GhostNicTargetVmResourceIds` Automation variable and grant the Automation identity the same VM-scoped role on that VM. Do not grant subscription-wide authority merely for convenience.

### CLI deployment

Prerequisites: PowerShell 7+, Azure PowerShell modules (`Az.Accounts`, `Az.Resources`, `Az.Automation`), Azure CLI with Bicep available, and an Azure identity permitted to create the Automation account. To grant the runbook identity access, the deployer also needs `Microsoft.Authorization/roleAssignments/write` at each selected scope.

```powershell
Connect-AzAccount
./deploy/Deploy-GhostNicHunter.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -Location 'westus3' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -TargetResourceGroupIds @(
    '/subscriptions/<subscription-id>/resourceGroups/<vm-resource-group-1>'
    '/subscriptions/<subscription-id>/resourceGroups/<vm-resource-group-2>'
  ) `
  -LogAnalyticsWorkspaceResourceId '/subscriptions/<subscription-id>/resourceGroups/<monitoring-rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

`TargetResourceGroupIds` grants the Automation identity **Virtual Machine Contributor** separately at each selected resource-group scope, which is the minimum built-in role that includes `Microsoft.Compute/virtualMachines/runCommand/write`. The runbook discovers Windows VMs in those groups and honors the `ghostNicHunterExclusions` VM tag (`scan`, `remove`, or `scan,remove`).

The Bicep deployment creates only the Automation account and its managed identity. The script imports and publishes the runbook, then grants the identity its selected resource-group scopes.

Supplying `LogAnalyticsWorkspaceResourceId` uses an existing workspace. If omitted, the deployment creates a tagged 30-day Log Analytics workspace, configures Automation `JobLogs` and `JobStreams`, and deploys the **Ghost NIC Hunter dashboard** workbook automatically.

## Start a job

### Runtime settings

The deployment creates these editable Automation Account variables. Explicit job parameters override their corresponding variables for that job.

| Variable | Default | Purpose |
|---|---:|---|
| `GhostNicOperation` | `Detect` | Default run mode; set to `Remove` only for an approved maintenance operation. |
| `GhostNicConfirmRemoval` | `false` | Second removal gate. Both this and `GhostNicOperation=Remove` are required. |
| `GhostNicMaximumCandidateCount` | `1000` | Per-VM candidate safety ceiling. |
| `GhostNicExclusionTagName` | `ghostNicHunterExclusions` | VM tag used for exclusions. |
| `GhostNicScanExclusionValues` | `scan,all` | Tag values that block scanning and removal. |
| `GhostNicRemovalExclusionValues` | `remove,all` | Tag values that allow detection but block removal. |
| `GhostNicPnpCleanWaitSeconds` | `10` | Delay between PnpClean and the pnputil fallback. |
| `GhostNicRequireProblemCode45` | `true` | Require `CM_PROB_PHANTOM` code 45 before pnputil removal. |

The target resource groups are stored separately in `GhostNicTargetResourceGroupIds`. The runbook uses Az modules only; do not import AzureRM modules into the same runbook session.

### Daily schedule

Deployment creates and links an enabled Automation schedule named `GhostNic-Daily-Detect-1230`. It runs every day at **12:30 PM Pacific time** (`America/Los_Angeles`, including daylight-saving adjustments) with `Operation=Detect`. An administrator can change or disable it under **Automation Account → Shared Resources → Schedules**.

Before issuing VM Run Command, the runbook checks Azure power state in batches. VMs that are not `VM running` are recorded as `OfflineSkipped` with `CommandIssued=false`, avoiding the Run Command timeout for stopped or deallocated hosts.

Detection is safe and is the normal first job:

```powershell
$params = @{
  TargetVmResourceIds = @(
    '/subscriptions/<subscription-id>/resourceGroups/<vm-rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>'
  )
  Operation = 'Detect'
}
Start-AzAutomationRunbook -ResourceGroupName '<automation-rg>' -AutomationAccountName 'vr-ghostnic-prod' -Name 'Invoke-GhostNicMaintenance' -Parameters $params
```

Removal should only follow a reviewed detection result and a current VM recovery point:

```powershell
$params.Operation = 'Remove'
$params.ConfirmRemoval = $true
Start-AzAutomationRunbook -ResourceGroupName '<automation-rg>' -AutomationAccountName 'vr-ghostnic-prod' -Name 'Invoke-GhostNicMaintenance' -Parameters $params
```

For a job’s output, use `Get-AzAutomationJobOutput` and `Get-AzAutomationJobOutputRecord`. Large cleanup jobs can take an hour or more on heavily affected VMs, as Microsoft notes.

## Dashboard

The optional Azure Monitor Workbook has four evidence views: current total/VM count, a current top-offenders table (newest successful scan per VM), a cumulative offender table (including cleaned VMs), and weekly registry-path removals. The cumulative ranking intentionally retains repeated findings so a recurring VM-level cause is visible.

## Safety and scope

- Targets must be full Azure VM resource IDs and are validated before a command is sent.
- The runbook only supports Windows VMs through `RunPowerShellScript`.
- It deliberately does not stop, deallocate, restart, snapshot, or modify Azure VM resources.
- A removal job fails closed unless both confirmation switches are supplied.
- Run Command requires the VM agent to be healthy and only one command can run at a time on a VM.

The device-classification and cleanup approach is derived from Microsoft’s [detection](https://github.com/Azure/azure-support-scripts/tree/master/RunCommand/Windows/Windows_GhostedNIC_Detection) and [removal](https://github.com/Azure/azure-support-scripts/tree/master/RunCommand/Windows/Windows_GhostedNIC_Removal) samples. Microsoft’s samples are provided as-is; this project supplies the Automation orchestration and more restrictive execution gate.

## Layout

- `infra/main.bicep` — Automation account with system-assigned managed identity.
- `runbooks/Invoke-GhostNicMaintenance.ps1` — Azure Automation entry point and in-guest cleanup payload.
- `deploy/Deploy-GhostNicHunter.ps1` — idempotent account/runbook deployment and optional least-scope role assignment.
- `docs/operations.md` — operational runbook, outputs, and rollback boundary.
