[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-f-]+/resourceGroups/[^/]+/providers/Microsoft\.Automation/automationAccounts/[^/]+$')]
    [string]$AutomationAccountResourceId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$RunbookName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ScheduleName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$JobScheduleId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ScheduleLinkerClientId,

    [Parameter(Mandatory)]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$AzureEnvironmentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JobSchedules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$DefaultProfile
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-AzRestMethod -Path $Path -Method GET -DefaultProfile $DefaultProfile
            return ($response.Content | ConvertFrom-Json)
        }
        catch {
            if ($attempt -eq 30) {
                throw
            }

            Start-Sleep -Seconds 10
        }
    }
}

Disable-AzContextAutosave -Scope Process | Out-Null

$resourceIdParts = $AutomationAccountResourceId.Trim('/') -split '/'
$subscriptionId = $resourceIdParts[1]
$azureContext = (Connect-AzAccount -Identity -AccountId $ScheduleLinkerClientId -Environment $AzureEnvironmentName).Context
$azureContext = Set-AzContext -SubscriptionId $subscriptionId -DefaultProfile $azureContext

$collectionPath = "$AutomationAccountResourceId/jobSchedules?api-version=2023-11-01"
$jobSchedules = Get-JobSchedules -Path $collectionPath -DefaultProfile $azureContext
$existingAssociation = @($jobSchedules.value | Where-Object {
        $_.properties.runbook.name -eq $RunbookName -and
        $_.properties.schedule.name -eq $ScheduleName
    })

if ($existingAssociation.Count -gt 0) {
    Write-Output 'GHNIC_SCHEDULE:{"Succeeded":true,"Changed":false,"Reason":"AssociationAlreadyExists"}'
    return
}

$associationBody = @{
    properties = @{
        parameters = @{
            Operation = 'Detect'
        }
        runbook = @{
            name = $RunbookName
        }
        schedule = @{
            name = $ScheduleName
        }
    }
} | ConvertTo-Json -Depth 6 -Compress

$associationPath = "$AutomationAccountResourceId/jobSchedules/$JobScheduleId`?api-version=2023-11-01"

try {
    Invoke-AzRestMethod -Path $associationPath -Method PUT -Payload $associationBody -DefaultProfile $azureContext | Out-Null
}
catch {
    # A concurrent deployment may have created the association after the initial list.
    $createError = $_
    $jobSchedules = Get-JobSchedules -Path $collectionPath -DefaultProfile $azureContext
    $existingAssociation = @($jobSchedules.value | Where-Object {
            $_.properties.runbook.name -eq $RunbookName -and
            $_.properties.schedule.name -eq $ScheduleName
        })

    if ($existingAssociation.Count -eq 0) {
        throw $createError
    }
}

Write-Output 'GHNIC_SCHEDULE:{"Succeeded":true,"Changed":true,"Reason":"AssociationCreated"}'
