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

The **Encrypt Automation Variables** choice defaults to `true`. Keep it enabled for the recommended policy-compliant deployment, or choose `false` when operators intentionally need portal-readable variables and policy permits them. See [Automation variable encryption](#automation-variable-encryption) before selecting a mode for an existing installation.

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

## Automation variable encryption

The deployment creates seven Ghost NIC Hunter Automation variables. The `Encrypt Automation Variables` portal option and the CLI `EncryptAutomationVariables` parameter apply one storage mode to all seven when they are first created.

| Deployment choice | Storage and visibility | When to use it |
|---|---|---|
| `true` (default) | Encrypted. Values cannot be viewed in the Azure portal or retrieved by external PowerShell after creation; they can still be read by the maintenance runbook and updated by `Configure-GhostNicHunter`. | Recommended and compatible with the Azure Policy definition **Automation account variables should be encrypted**, including assignments using `Deny`. |
| `false` | Normal. Values remain readable and editable in the Azure portal. | Use only when operator visibility is required and the applicable policy allows unencrypted Automation variables. |

Azure fixes the encryption mode when each variable is created. Redeploying with the opposite choice does not convert an existing variable and can fail because its encryption state is immutable. See [Manage variables in Azure Automation](https://learn.microsoft.com/en-us/azure/automation/shared-resources/variables).

### New encrypted deployment: runbook order

For a new encrypted installation, deploy with **Encrypt Automation Variables** set to `true` (the default). Use the components in this order:

| Order | Component | Who runs it | Purpose |
|---|---|---|---|
| 1 | Portal deployment or `Deploy-GhostNicHunter.ps1` | Operator, once | Creates the Automation account, encrypted variables, managed identity, runbooks, role assignments, monitoring, and daily Detect schedule. |
| 2 | `Initialize-GhostNicSchedule` | Deployment, automatically | Links the daily Detect schedule during a portal deployment. The CLI deployment performs the equivalent setup directly. Do not start this runbook manually during a normal deployment. |
| 3 | `Configure-GhostNicHunter` | Operator, only if defaults must change | Preview persistent behavior changes first, then rerun with `ApplyChanges=true`. Skip this runbook when the documented defaults are acceptable. |
| 4 | `Invoke-GhostNicMaintenance` with `Operation=Detect` | Operator, once for validation; then the schedule | Performs the first read-only scan. Review its output before accepting the scheduled deployment. |
| 5 | `Invoke-GhostNicMaintenance` with `Operation=Remove` and `ConfirmRemoval=true` | Operator, manually and only when approved | Removes reviewed candidates. Removal is never enabled by the schedule or a persistent variable. |

Do **not** run `Convert-GhostNicHunterVariablesToEncrypted.ps1` for a new deployment. That local helper exists only to convert an existing installation whose variables are currently normal.

#### Azure portal sequence

1. Start the [portal deployment](#portal-deployment), leave **Encrypt Automation Variables** set to `true`, select the target resource groups, and wait for the Azure deployment to complete.
2. Open the deployed Automation account, select **Runbooks**, and verify that `Invoke-GhostNicMaintenance`, `Configure-GhostNicHunter`, and `Initialize-GhostNicSchedule` are published.
3. Under **Schedules**, verify that `GhostNic-Daily-Detect-1230` is enabled. Under **Jobs**, verify that the one-time `Initialize-GhostNicSchedule` bootstrap job completed. Do not manually start that runbook unless recovering a failed deployment.
4. If the default behavior settings are acceptable, skip to step 5. Otherwise, open `Configure-GhostNicHunter`, select **Start**, enter only the intended changes, and leave `ApplyChanges` false. Review the `GHNIC_CONFIG:` output, then start it again with the same settings and `ApplyChanges=true`.
5. Open `Invoke-GhostNicMaintenance`, select **Start**, and set `Operation` to `Detect`. Leave `ConfirmRemoval` false and leave both target parameters blank to use the resource groups selected at deployment. Review every `GHNIC_RESULT:` output record and resolve scope, permission, or Run Command errors.
6. The daily schedule can now remain enabled for Detect-only operation. If removal is later approved, first take the required recovery point, review a current Detect job, and then manually start `Invoke-GhostNicMaintenance` with both `Operation=Remove` and `ConfirmRemoval=true`.

Azure's [runbook start guide](https://learn.microsoft.com/en-us/azure/automation/start-runbooks) describes the portal job pane and parameter-entry flow.

#### PowerShell sequence

The following commands use the same order and wait for each job before continuing. Sign in first with `Connect-AzAccount`, then replace the two placeholders:

```powershell
$automation = @{
  ResourceGroupName     = '<automation-resource-group>'
  AutomationAccountName = 'vr-ghostnic-prod'
}

function Wait-GhostNicJob {
  param(
    [Parameter(Mandatory)] $Job,
    [Parameter(Mandatory)] [hashtable] $Automation
  )

  do {
    Start-Sleep -Seconds 5
    $Job = Get-AzAutomationJob @Automation -Id $Job.JobId
  } while ($Job.Status -notin @('Completed', 'Failed', 'Stopped', 'Suspended'))

  Get-AzAutomationJobOutput @Automation -Id $Job.JobId -Stream Any

  if ($Job.Status -ne 'Completed') {
    throw "Automation job $($Job.JobId) ended with status $($Job.Status)."
  }
}
```

If defaults are acceptable, skip configuration. Otherwise, preview the desired persistent changes and review `GHNIC_CONFIG:` before applying the same values:

```powershell
$settings = @{
  MaximumCandidateCount = 500
  PnpCleanWaitSeconds    = 20
  RequireProblemCode45   = $true
}

$job = Start-AzAutomationRunbook @automation `
  -Name 'Configure-GhostNicHunter' `
  -Parameters $settings
Wait-GhostNicJob -Job $job -Automation $automation

$settings['ApplyChanges'] = $true
$job = Start-AzAutomationRunbook @automation `
  -Name 'Configure-GhostNicHunter' `
  -Parameters $settings
Wait-GhostNicJob -Job $job -Automation $automation
```

Run the first Detect job and review every `GHNIC_RESULT:` record. Omitting target parameters uses the resource groups selected during deployment:

```powershell
$job = Start-AzAutomationRunbook @automation `
  -Name 'Invoke-GhostNicMaintenance' `
  -Parameters @{ Operation = 'Detect' }
Wait-GhostNicJob -Job $job -Automation $automation
```

Removal is a separate, manual change. Run it only after the recovery and approval checks in [Remove confirmed ghost NICs](#remove-confirmed-ghost-nics):

```powershell
$job = Start-AzAutomationRunbook @automation `
  -Name 'Invoke-GhostNicMaintenance' `
  -Parameters @{
    Operation      = 'Remove'
    ConfirmRemoval = $true
  }
Wait-GhostNicJob -Job $job -Automation $automation
```

### Conversion options

| Current state | Desired state | Supported path |
|---|---|---|
| New installation | Encrypted | Deploy with `Encrypt Automation Variables=true`, which is the default. |
| New installation | Normal | Deploy with `Encrypt Automation Variables=false`, provided policy permits it. |
| Existing normal variables | Encrypted | Use the guarded conversion helper below, redeploy with encryption enabled, then restore customized behavior settings. |
| Existing encrypted variables | Normal | There is no automatic reverse conversion because external PowerShell cannot read the encrypted values. The safest option is a new deployment with normal variables and explicitly supplied replacement settings. |
| Existing variables | Same mode | Redeploy with the existing choice. Remember that deployment resets the six behavior settings to their documented defaults. |

### Convert normal variables to encrypted variables

The helper performs only normal-to-encrypted conversion. It blocks while any Automation job is nonterminal, pauses the enabled daily schedule, keeps normal values in process memory only, removes obsolete persistent variables, recreates the seven current variables as encrypted, verifies them, and restores the schedule. It does not print variable values. An interrupted conversion can be rerun safely; it converts only variables that remain normal.

1. Record any customized values for the six behavior settings in an approved change record. The redeployment in step 5 resets them to defaults, and external tools cannot read them after encryption.
2. Confirm no maintenance or configuration job should be running during the conversion.
3. Sign in to the subscription containing the Automation account and review the conversion plan:

```powershell
Connect-AzAccount

./deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1 `
  -SubscriptionId '<automation-subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -ConfirmMigration `
  -WhatIf
```

4. Apply the conversion. PowerShell presents a final confirmation prompt before it deletes and recreates any normal variables:

```powershell
./deploy/Convert-GhostNicHunterVariablesToEncrypted.ps1 `
  -SubscriptionId '<automation-subscription-id>' `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -ConfirmMigration
```

5. Redeploy Ghost NIC Hunter with the same Automation account and target resource groups, using the portal wizard with **Encrypt Automation Variables** enabled or rerunning the [CLI deployment](#cli-deployment) with `EncryptAutomationVariables=$true`.
6. Reapply the recorded behavior settings using [Change persistent behavior](#change-persistent-behavior) with `ApplyChanges=$true`.
7. Verify that exactly seven current Ghost NIC Hunter variables remain, all report `Encrypted=True`, and obsolete variables are absent:

```powershell
Get-AzAutomationVariable `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName 'vr-ghostnic-prod' |
  Where-Object Name -Like 'GhostNic*' |
  Select-Object Name, @{
    Name = 'Encrypted'
    Expression = {
      if ($_.PSObject.Properties['Encrypted']) { [bool]$_.Encrypted } else { [bool]$_.IsEncrypted }
    }
  }
```

8. Confirm `GhostNic-Daily-Detect-1230` is enabled and run a `Detect` job before scheduling any removal work.

If conversion fails, the helper leaves the schedule disabled and reports the failed stage without outputting values. Resolve the Azure error and rerun the same command; mixed encrypted/normal state from the interrupted attempt is supported. After a successful retry, verify and, if necessary, re-enable the schedule manually:

```powershell
Set-AzAutomationSchedule `
  -ResourceGroupName '<automation-resource-group>' `
  -AutomationAccountName 'vr-ghostnic-prod' `
  -Name 'GhostNic-Daily-Detect-1230' `
  -IsEnabled $true
```

### Convert encrypted variables to normal variables

Encrypted-to-normal conversion is intentionally not automated. Azure does not allow external PowerShell to retrieve encrypted variable values, so an in-place conversion cannot safely preserve them.

The recommended path is:

1. Confirm that policy allows normal Automation variables. A `Deny` assignment for unencrypted variables will block the deployment.
2. Create a separate Ghost NIC Hunter deployment in another resource group or with a distinct Automation account name, using `Encrypt Automation Variables=false`.
3. Supply the intended target groups and explicitly reapply all six behavior settings from an approved source.
4. Run and review a `Detect` job from the replacement deployment.
5. Only after validation, disable the old schedule and retire the old Automation account through the normal change-control process.

An in-place reverse conversion requires deleting all seven encrypted variables and recreating them with complete replacement values. Do not use that path unless the values are available independently and an outage is acceptable.

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
