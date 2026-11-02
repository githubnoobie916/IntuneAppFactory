#requires -Version 7.2
<#
.SYNOPSIS
Publish an existing factory revision's .intunewin as a new Win32 app.
.DESCRIPTION
Use -Preview or -WhatIf for local validation without authentication or tenant writes.
Per-app publishing defaults come from the revision's intune.upload JSON object.
Explicit DeployMode, MinimumSupportedWindowsRelease, RestartBehavior and TimeoutSeconds override JSON.
Requires Microsoft.Graph.Authentication for live upload. See ../UPLOADING.md.
.PARAMETER GroupId
Optional single pilot group. AssignmentIntent is also required; omitted means no assignment.
.PARAMETER UseExistingConnection
Use a pre-established Graph session after verifying its tenant and public-cloud environment.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RevisionPath,
    [string]$IntuneWinPath,
    [ValidateSet('Auto','Silent','NonInteractive','Interactive')][string]$DeployMode,
    [string]$MinimumSupportedWindowsRelease,
    [ValidateSet('basedOnReturnCode','suppress','allow','force')][string]$RestartBehavior,
    [guid]$TenantId = [guid]::Empty,
    [guid]$ClientId = [guid]::Empty,
    [string]$CertificateThumbprint,
    [switch]$UseDeviceCode,
    [switch]$UseExistingConnection,
    [guid]$GroupId = [guid]::Empty,
    [ValidateSet('available','required')][string]$AssignmentIntent,
    [ValidateRange(1,7200)][int]$TimeoutSeconds,
    [switch]$Preview
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/IntuneUpload.ps1"
if ($PSBoundParameters.ContainsKey('GroupId') -xor $PSBoundParameters.ContainsKey('AssignmentIntent')) { throw 'Specify both GroupId and AssignmentIntent, or neither.' }
if ($PSBoundParameters.ContainsKey('GroupId') -and $GroupId -eq [guid]::Empty) { throw 'GroupId cannot be an empty GUID.' }
if ($CertificateThumbprint -and ($ClientId -eq [guid]::Empty -or $UseDeviceCode)) { throw 'Certificate authentication requires ClientId and cannot be combined with UseDeviceCode.' }
if ($UseExistingConnection -and ($CertificateThumbprint -or $UseDeviceCode -or $PSBoundParameters.ContainsKey('ClientId'))) { throw 'UseExistingConnection cannot be combined with connection options.' }
$planOptions = @{ RevisionPath=$RevisionPath; IntuneWinPath=$IntuneWinPath }
foreach ($name in @('DeployMode','MinimumSupportedWindowsRelease','RestartBehavior','TimeoutSeconds')) {
    if ($PSBoundParameters.ContainsKey($name)) { $planOptions[$name] = $PSBoundParameters[$name] }
}
$plan = Get-FactoryUploadPlan @planOptions
$TimeoutSeconds = $plan.Transport.TimeoutSeconds
if ($PSBoundParameters.ContainsKey('GroupId')) {
    $plan.Assignments = @(@{
        '@odata.type'='#microsoft.graph.mobileAppAssignment'; intent=$AssignmentIntent
        target=@{'@odata.type'='#microsoft.graph.groupAssignmentTarget';groupId=$GroupId.ToString()}
        settings=@{'@odata.type'='#microsoft.graph.win32LobAppAssignmentSettings';notifications='showAll'}
    })
}
if ($Preview) { return $plan }
$action = 'Create and upload a Win32 app'
if ($plan.Assignments.Count) { $action += "; assign $AssignmentIntent to group $GroupId" }
if (-not $PSCmdlet.ShouldProcess("$($plan.AppBody.displayName) in tenant $TenantId", $action)) { return $plan }
if ($TenantId -eq [guid]::Empty) { throw 'TenantId is required for live upload.' }
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Install Microsoft.Graph.Authentication first. See UPLOADING.md. Preview requires no module.'
}
# Hold the archive open without write/delete sharing from final hash check through commit.
$packageLock = [IO.File]::Open($plan.IntuneWinPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$connectedHere = $false
try {
    if ((Get-FileHash -LiteralPath $plan.IntuneWinPath -Algorithm SHA256).Hash -ne $plan.SHA256) { throw 'The archive changed after preflight. Run preview again.' }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    if (-not $UseExistingConnection) {
        $connect = @{TenantId=$TenantId.ToString();Environment='Global';ContextScope='Process';NoWelcome=$true;ErrorAction='Stop'}
        if ($ClientId -ne [guid]::Empty) { $connect.ClientId = $ClientId.ToString() }
        if ($CertificateThumbprint) { $connect.CertificateThumbprint = $CertificateThumbprint }
        else {
            $connect.Scopes = @('DeviceManagementApps.ReadWrite.All')
            if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
        }
        $null = Connect-MgGraph @connect
        $connectedHere = $true
    }
    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $TenantId.ToString() -or $context.Environment -ne 'Global') { throw 'Graph session does not match TenantId and the public cloud.' }
    if ($context.AuthType -eq 'Delegated' -and 'DeviceManagementApps.ReadWrite.All' -notin $context.Scopes) { throw 'Graph session lacks DeviceManagementApps.ReadWrite.All.' }
 #   Import-FactoryBlobClient
    Invoke-FactoryPublishPlan -Plan $plan -TenantId $TenantId -TimeoutSeconds $TimeoutSeconds
} finally {
    $packageLock.Dispose()
    if ($connectedHere) { $null = Disconnect-MgGraph -ErrorAction SilentlyContinue }
}
