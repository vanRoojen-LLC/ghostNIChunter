# Ghost NIC Hunter

Ghost NIC Hunter is a small vanRoojen LLC Azure utility for detecting and, only with an explicit second confirmation, removing stale Windows network-device entries caused by Azure Accelerated Networking after a VM is deallocated and allocated again.

It deploys an Azure Automation account with managed identities and publishes the `Invoke-GhostNicMaintenance` and `Configure-GhostNicHunter` PowerShell runbooks. A small `Initialize-GhostNicSchedule` bootstrap runbook safely creates the daily schedule association, then the maintenance runbook uses Azure VM Run Command without a Hybrid Runbook Worker or credentials stored in Automation.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FvanRoojen-LLC%2FghostNIChunter%2Fmain%2Fdeploy%2Fazuredeploy-20260806.json)
[![Deploy to Azure Gov](deploy/deploytoazuregov.svg)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FvanRoojen-LLC%2FghostNIChunter%2Fmain%2Fdeploy%2Fazuredeploy-20260806.json)

## What it does

- **Detect** (the default) inventories active and ghosted `netvsc`, `mlx5`, and `mlx4_bus` NIC entries on one or more Azure Windows VMs.
- **Remove** runs the same inventory, invokes Windows `pnpclean`, then removes only the registry entries classified as ghosted. It requires both `Operation=Remove` and `ConfirmRemoval=$true`.
- Emits one structured JSON result per VM, as well as the captured Run Command output.

Microsoft describes this as a design behavior of Accelerated Networking after deallocation/reallocation; it recommends checking first and making cleanup regular maintenance when appropriate. It also advises a recovery point before removal. See [the Microsoft troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-vm-ghostednic-troubleshooting).

## Deploy

### Deploy to Azure portal wizard

Click **Deploy to Azure** above. Azure Portal will ask you to sign in, select the subscription and resource group, and enter one target resource-group ID or multiple IDs separated by commas. The wizard automatically generates the Automation account and a dedicated Log Analytics workspace, imports the runbooks, deploys the workbook, and grants its managed identity **Virtual Machine Contributor** on each selected target group. Target groups can span subscriptions in the same tenant when the deploying identity can create role assignments at every selected scope.

The **Encrypt Automation Variables** choice defaults to `true`. Keep it enabled for the normal policy-compliant deployment. Choosing `false` creates normal variables whose values remain readable in the portal, but a policy assignment using the strict `Deny` effect for unencrypted Automation variables will reject that deployment. Azure does not allow an existing variable's encryption mode to be changed in place; use the migration workflow below before switching an existing plaintext installation to encrypted variables. See [Manage variables in Azure Automation](https://learn.microsoft.com/en-us/azure/automation/shared-resources/variables).

The deploying identity needs permission to create the Automation account, workspace, workbook, managed identity, Automation jobs, and role assignments. A helper user-assigned identity has Automation Contributor only on the generated Automation account; a one-time bootstrap job uses it to link the runbook to its schedule without creating a duplicate association. This does not use Deployment Scripts, temporary storage accounts, or container instances. The portal deployment does not run remediation; start the imported runbook with its safe `Detect` default after it completes.

Change target resource groups through the portal or CLI deployment workflow, not through the configuration runbook. That workflow updates `GhostNicTargetResourceGroupIds` and grants the managed identity at each selected group. Explicitly remove obsolete role assignments when a group leaves scope; do not grant subscription-wide authority merely for convenience.

### CLI deployment

Prerequisites: PowerShell 7+, Azure PowerShell modules (`Az.Accounts`, `Az.Resources`, `Az.Automation`), Azure CLI with Bicep available, and an Azure identity permitted to create the Automation account. To grant the runbook identity access, the deployer also needs `Microsoft.Authorization/roleAssignments/write` at each selected scope.

```powershell
Connect-AzAccount
./deploy/Deploy-GhostNicHunter.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -Location 'westus3' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -EncryptAutomationVariables $true `
  -TargetResourceGroupIds @(
    '/subscriptions/<subscription-id>/resourceGroups/<vm-resource-group-1>'
    '/subscriptions/<other-subscription-id>/resourceGroups/<vm-resource-group-2>'
  ) `
  -LogAnalyticsWorkspaceResourceId '/subscriptions/<subscription-id>/resourceGroups/<monitoring-rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

`EncryptAutomationVariables` defaults to `$true`; pass `$false` only when readable normal variables are intentional and policy permits them. `TargetResourceGroupIds` grants the Automation identity **Virtual Machine Contributor** separately at each selected resource-group scope, which is the minimum built-in role that includes `Microsoft.Compute/virtualMachines/runCommand/write`. The target IDs can span subscriptions in the signed-in tenant; the runbook selects each target subscription before discovery and Run Command. It discovers Windows VMs in those groups and honors the `ghostNicHunterExclusions` VM tag (`scan`, `remove`, or `scan,remove`).

The Bicep deployment creates the Automation account, managed identity, seven variables, monitoring resources, and workbook. The script imports and publishes both operator-facing runbooks, then grants the identity its selected resource-group scopes.

Supplying `LogAnalyticsWorkspaceResourceId` uses an existing workspace. If omitted, the deployment creates a tagged 30-day Log Analytics workspace, configures Automation `JobLogs` and `JobStreams`, and deploys the **Ghost NIC Hunter dashboard** workbook automatically.

## Start a job

### Runtime settings

The deployment creates six persistent behavior variables. Explicit maintenance-job parameters override their corresponding variables for that job.

| Variable | Default | Purpose |
|---|---:|---|
| `GhostNicMaximumCandidateCount` | `1000` | Per-VM candidate safety ceiling. |
| `GhostNicExclusionTagName` | `ghostNicHunterExclusions` | VM tag used for exclusions. |
| `GhostNicScanExclusionValues` | `scan,all` | Tag values that block scanning and removal. |
| `GhostNicRemovalExclusionValues` | `remove,all` | Tag values that allow detection but block removal. |
| `GhostNicPnpCleanWaitSeconds` | `10` | Delay between PnpClean and the pnputil fallback. |
| `GhostNicRequireProblemCode45` | `true` | Require `CM_PROB_PHANTOM` code 45 before pnputil removal. |

The seventh variable, `GhostNicTargetResourceGroupIds`, stores the selected resource-group scope. `Operation` and `ConfirmRemoval` are deliberately not persistent variables: every removal job must explicitly supply both `Operation=Remove` and `ConfirmRemoval=$true`, while an omitted operation always defaults to `Detect`.

All seven variables use the deployment's encryption choice. Encrypted variables are write-only in the Azure portal; normal variables remain readable. `Configure-GhostNicHunter` provides the same validated update experience in either mode without printing values.

### Change persistent behavior

Start `Configure-GhostNicHunter` with only the behavior settings that should change. `ApplyChanges=$true` is required to write them; without it, the runbook validates and previews the names and count of proposed changes. Its output never includes setting values.

```powershell
$config = @{
  MaximumCandidateCount = 500
  PnpCleanWaitSeconds = 20
  RequireProblemCode45 = $true
  ApplyChanges = $true
}
Start-AzAutomationRunbook -ResourceGroupName '<automation-rg>' -AutomationAccountName 'vr-ghostnic-prod' -Name 'Configure-GhostNicHunter' -Parameters $config
```

Target scope is not changed by this runbook because target changes also require matching Azure RBAC changes. Redeploying the template resets the six persistent behavior values to their documented defaults, so reapply any intended custom configuration afterward. The runbooks use Az modules only; do not import AzureRM modules into the same runbook session.

### Migrate existing plaintext variables

Encryption is immutable after a variable is created. Before migrating, record any customized values for the six behavior settings in your approved change record; the required redeployment resets them to defaults, and encrypted values cannot be read back through external PowerShell. Then run `deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1` before redeploying with encryption enabled. The helper refuses every nonterminal Automation job, pauses an enabled daily schedule, holds only the normal values in process memory, removes the obsolete `GhostNicOperation`, `GhostNicConfirmRemoval`, and persistent `GhostNicTargetVmResourceIds` assets, recreates the seven current variables encrypted, and verifies the result before restoring the schedule. It can safely resume a mixed state left by an interrupted prior migration by converting only the remaining normal variables. It does not print values, and it leaves the schedule disabled if migration fails. Review its WhatIf output first:

```powershell
./deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -ConfirmMigration `
  -WhatIf

./deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -ConfirmMigration
```

Redeploy with `EncryptAutomationVariables=$true`, then immediately reapply the recorded behavior settings through `Configure-GhostNicHunter`. If a failed migration disabled the schedule, verify the retry result and re-enable the schedule manually. The helper only supports plaintext-to-encrypted migration. An encrypted variable cannot be read externally for a reverse migration, so switching to normal variables requires deleting and recreating them with complete replacement values.

### Daily schedule

Deployment creates and links an enabled Automation schedule named `GhostNic-Daily-Detect-1230`. It runs every day at **12:30 PM Pacific time** (`America/Los_Angeles`, including daylight-saving adjustments) with `Operation=Detect`. The deployment checks for an existing runbook/schedule association before creating one, so the same environment can be redeployed safely. An administrator can change or disable it under **Automation Account → Shared Resources → Schedules**.

Before issuing VM Run Command, the runbook checks Azure power state in batches. VMs that are not `VM running` are recorded as `OfflineSkipped` with `CommandIssued=false`, avoiding the Run Command timeout for stopped or deallocated hosts.

Detection is safe and is the normal first job:

```powershell
$params = @{
  TargetVmResourceIds = '/subscriptions/<subscription-id>/resourceGroups/<vm-rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>'
  Operation = 'Detect'
}
Start-AzAutomationRunbook -ResourceGroupName '<automation-rg>' -AutomationAccountName 'vr-ghostnic-prod' -Name 'Invoke-GhostNicMaintenance' -Parameters $params
```

In the Azure portal Start pane, paste a single resource ID directly into `TargetVmResourceIds`. Multiple IDs can be comma-, semicolon-, or newline-separated; a JSON string array is also accepted. This string-based input avoids Azure Automation's generic pre-start failure when a scalar value is submitted to an array-typed runbook parameter.

Removal should only follow a reviewed detection result and a current VM recovery point:

```powershell
$params.Operation = 'Remove'
$params.ConfirmRemoval = $true
Start-AzAutomationRunbook -ResourceGroupName '<automation-rg>' -AutomationAccountName 'vr-ghostnic-prod' -Name 'Invoke-GhostNicMaintenance' -Parameters $params
```

For a job’s output, use `Get-AzAutomationJobOutput` and `Get-AzAutomationJobOutputRecord`. Large cleanup jobs can take an hour or more on heavily affected VMs, as Microsoft notes.

## Dashboard

The optional Azure Monitor Workbook has four evidence views: current total/VM count, a current top-offenders table (newest successful scan per VM), a cumulative offender table (including cleaned VMs), and weekly ghost-NIC removals. Structured removal results contribute their reported removal counts even when final safety validation returns `SafetyAbort` or `PartialFailure`; those outcomes remain identified separately and are not presented as successful remediation. Both VM tables merge the scan records with Azure Resource Graph power state whenever the workbook refreshes. The separate `Last-run status` column remains visible as a fallback for a deleted VM, a VM outside the viewer's Resource Graph access, or a live-status query that cannot return a match. The cumulative ranking intentionally retains repeated findings so a recurring VM-level cause is visible.

## Safety and scope

- Targets must be full Azure VM resource IDs and are validated before a command is sent.
- The runbook only supports Windows VMs through `RunPowerShellScript`.
- It deliberately does not stop, deallocate, restart, snapshot, or modify Azure VM resources.
- A removal job fails closed unless both per-job confirmation values are supplied; neither gate can be persisted as an Automation variable.
- After cleanup, active adapters are matched by PnP ID, interface GUID, or MAC address for up to six five-second validation attempts. A re-enumerated healthy adapter is reported as `PassedWithChanges`; `SafetyAbort` is reserved for a previously active adapter that remains missing or not up.
- Run Command requires the VM agent to be healthy and only one command can run at a time on a VM.

The device-classification and cleanup approach is derived from Microsoft’s [detection](https://github.com/Azure/azure-support-scripts/tree/master/RunCommand/Windows/Windows_GhostedNIC_Detection) and [removal](https://github.com/Azure/azure-support-scripts/tree/master/RunCommand/Windows/Windows_GhostedNIC_Removal) samples. Microsoft’s samples are provided as-is; this project supplies the Automation orchestration and more restrictive execution gate.

## Layout

- `infra/main.bicep` — Automation account with system-assigned managed identity.
- `runbooks/Invoke-GhostNicMaintenance.ps1` — Azure Automation entry point and in-guest cleanup payload.
- `runbooks/Configure-GhostNicHunter.ps1` — validated updates for the six persistent behavior settings.
- `runbooks/Initialize-GhostNicSchedule.ps1` — storage-free, idempotent schedule-link bootstrap runbook.
- `deploy/Deploy-GhostNicHunter.ps1` — idempotent account/runbook deployment and optional least-scope role assignment.
- `deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1` — guarded plaintext-to-encrypted variable migration.
- `docs/operations.md` — operational runbook, outputs, and rollback boundary.
