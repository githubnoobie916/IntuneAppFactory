#requires -Version 5.1
<#
.SYNOPSIS
Validate one application version or build its standalone PSADT 4.1.8 package.
.DESCRIPTION
Builds apps/<AppName>/<Version>/output/rev-<Revision> relative to the factory directory.
After a successful build, prints commands to package, optionally preview, and upload the resolved revision.
Commands use absolute script paths and are not executed. Replace <tenant-guid> before live upload.
Upload and preview require PowerShell 7.2 or later. The build result remains a pipeline object.
.PARAMETER ValidateOnly
Validate JSON and paths without requiring installers or a staged toolkit. No output is created.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppName,
    [Parameter(Mandatory)][Alias('AppVersion')][string]$Version,
    [string]$Revision,
    [switch]$Force,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/AppConfig.ps1"
$projectRoot = Split-Path $PSScriptRoot -Parent
Assert-FactorySegment $AppName 'AppName'
Assert-FactorySegment $Version 'Version'
$appRoot = Get-FactoryPath $projectRoot "apps/$AppName"
$versionRoot = Get-FactoryPath $appRoot $Version
$configPath = Get-FactoryPath $versionRoot 'app.json'
$config = Read-FactoryConfig -Path $configPath -ExpectedVersion $Version -Revision $Revision
if ($ValidateOnly) {
    Write-Host "Configuration valid: $AppName $Version revision $($config.revision). Installer availability and template rendering were not checked."
    return [pscustomobject]@{ Status = 'ConfigurationValid'; AppName = $AppName; Version = $Version; Revision = $config.revision }
}

# Complete all input validation before creating output, including on forced rebuilds.
$installerRoot = Get-FactoryPath $versionRoot 'installers'
$payloadPaths = @(@($config.install) + @($config.uninstall) + @($config.repair) | ForEach-Object { if ($_.path) { $_.path } }) + @($config.additionalFiles)
$payloadPaths = @($payloadPaths | Sort-Object -Unique)
foreach ($relativePath in $payloadPaths) {
    $source = Get-FactoryPath $installerRoot $relativePath
    Assert-FactoryNoLinks $source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Installer file not found: '$source'. Supply the vendor file under this version's installers directory." }
}
$iconPath = $null
$detectionBytes = $null
if ($config.intune.detection.type -eq 'powershell') {
    $detectionPath = Get-FactoryPath $versionRoot $config.intune.detection.scriptPath
    $detectionBytes = Read-FactoryDetectionScript $detectionPath
}
if ($config.intune.icon) {
    $iconPath = Get-FactoryPath $appRoot $config.intune.icon
    Assert-FactoryNoLinks $iconPath
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw "Configured icon not found: '$iconPath'. Supply it or set intune.icon to an empty string." }
}
$templateRoot = Get-FactoryPath (Split-Path $projectRoot -Parent) 'sources/PSAppDeployToolkit_Template_v4'
Assert-FactoryNoLinks $templateRoot -Recurse
$manifestPath = Join-Path $templateRoot 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The original sources/PSAppDeployToolkit_Template_v4 template is missing.' }
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
if ($manifest.ModuleVersion -ne '4.1.8' -or $manifest.GUID -ne '8c3c366b-8606-4576-9f2d-4051144f7ca2') { throw 'Only the official PSADT 4.1.8 template is supported.' }
. "$PSScriptRoot/Update-DeploymentTemplate.ps1"

$target = Get-FactoryRevisionPath -ProjectRoot $projectRoot -AppName $AppName -Version $Version -Revision $config.revision
$versionOutput = Split-Path $target -Parent
$stage = Get-FactoryPath $versionOutput ('.stage-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$backup = Get-FactoryPath $versionOutput ('.backup-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
Assert-FactoryNoLinks $versionOutput
Assert-FactoryNoLinks $target -Recurse
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $templateFiles = @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($templateRoot.Length + 1) })
    $packageFiles = $templateFiles + @($payloadPaths | ForEach-Object { "Files/$_" })
    foreach ($parent in @($stage, $backup, $target)) {
        foreach ($relativePath in $packageFiles) {
            $candidate = Get-FactoryPath (Join-Path $parent 'Package') $relativePath
            if ($candidate.Length -ge 260 -or (Split-Path $candidate -Parent).Length -ge 248) {
                throw 'Output exceeds Windows PowerShell 5.1 path limits. Use PowerShell 7 or move IntuneAppFactory to a shorter path.'
            }
        }
    }
}
if (Test-Path -LiteralPath $target) {
    if (-not $Force) { throw "Output already exists: '$target'. Use -Force to rebuild this revision or choose -Revision." }
    $marker = Join-Path $target 'build.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Refusing to replace an unrecognized output folder: '$target'." }
    $previous = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($previous.factory -ne 'IntuneAppFactory' -or $previous.appName -cne $AppName -or $previous.version -cne $Version -or $previous.revision -cne $config.revision) { throw "Refusing to replace an unrecognized output folder: '$target'." }
}
New-Item -ItemType Directory -Path $versionOutput -Force | Out-Null
$lockPath = Get-FactoryPath $versionOutput ".rev-$($config.revision).lock"
Assert-FactoryNoLinks $lockPath
try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
catch { throw "Cannot acquire build lock '$lockPath'. Another build may be running; inspect any stale lock before removing it." }
$published = $false
$ownsStage = $false
$ownsBackup = $false
function Remove-BuildTemporaryDirectory([string]$Path) {
    $checked = Get-FactoryPath $versionOutput (Split-Path $Path -Leaf)
    if ($checked -ne $Path -or (Split-Path $Path -Leaf) -notmatch '^\.(stage|backup)-[0-9a-f]{12}$') { throw "Unsafe cleanup target: '$Path'." }
    Assert-FactoryNoLinks $checked -Recurse
    if (Test-Path -LiteralPath $checked) { Remove-Item -LiteralPath $checked -Recurse -Force }
}
try {
    if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $backup)) { throw 'Temporary build path already exists. Retry the build.' }
    # A competing build could have finished between preflight and lock acquisition.
    if ((Test-Path -LiteralPath $target) -and -not $Force) { throw "Output already exists: '$target'." }
    New-Item -ItemType Directory -Path $stage | Out-Null
    $ownsStage = $true
    $package = Join-Path $stage 'Package'
    New-Item -ItemType Directory -Path $package -Force | Out-Null
    Get-ChildItem -LiteralPath $templateRoot -Force | Copy-Item -Destination $package -Recurse -Force
    # Change only the generated entry script; the upstream source stays untouched.
    Update-FactoryDeploymentTemplate -Path (Join-Path $package 'Invoke-AppDeployToolkit.ps1') -Config $config
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $stage 'app.json') -Encoding UTF8
    foreach ($relativePath in $payloadPaths) {
        $source = Get-FactoryPath $installerRoot $relativePath
        $destination = Get-FactoryPath (Join-Path $package 'Files') $relativePath
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
    foreach ($required in @('Invoke-AppDeployToolkit.exe','Invoke-AppDeployToolkit.ps1','PSAppDeployToolkit/PSAppDeployToolkit.psd1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $package $required) -PathType Leaf)) { throw "Incomplete package: '$required' is missing." }
    }
    $icon = $null
    if ($iconPath) {
        Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stage 'icon.png')
        $icon = 'icon.png'
    }
    $installCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
    $detectionScript = $null
    if ($null -ne $detectionBytes) {
        New-Item -ItemType Directory -Path (Join-Path $stage 'Detection') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $stage 'Detection/Detect.ps1'), $detectionBytes)
        $detectionScript = [ordered]@{ path = 'Detection/Detect.ps1'; sha256 = Get-FactoryBytesHash $detectionBytes }
    }
    $uninstallCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
    $buildMetadata = [ordered]@{
        factory = 'IntuneAppFactory'; appName = $AppName; version = $Version; revision = $config.revision
        toolkitVersion = '4.1.8'; packageDirectory = 'Package'
        installCommand = $installCommand; uninstallCommand = $uninstallCommand
        repairCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Repair'
        icon = $icon; intune = $config.intune
    }
    if ($detectionScript) { $buildMetadata.detectionScript = $detectionScript }
    $buildMetadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $stage 'build.json') -Encoding UTF8

    # Publish only after staging succeeds. Keep the previous package until the swap succeeds.
    if (Test-Path -LiteralPath $target) {
        Assert-FactoryNoLinks $target -Recurse
        Move-Item -LiteralPath $target -Destination $backup
        $ownsBackup = $true
    }
    try { Move-Item -LiteralPath $stage -Destination $target; $published = $true }
    catch {
        if ($ownsBackup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $target }
        throw
    }
}
finally {
    try {
        if ($ownsStage) { Remove-BuildTemporaryDirectory $stage }
        if ($published -and $ownsBackup) { Remove-BuildTemporaryDirectory $backup }
    }
    finally { $lock.Dispose(); Remove-Item -LiteralPath $lockPath -Force }
}
Write-Host "Built: $(Join-Path $target 'Package')"
Write-Host "Install:   $installCommand"
Write-Host "Uninstall: $uninstallCommand"
$selection = "-AppName '{0}' -Version '{1}' -Revision '{2}'" -f $AppName.Replace("'", "''"), $Version.Replace("'", "''"), $config.revision.Replace("'", "''")
$packageScript = (Join-Path $PSScriptRoot 'New-IntuneWin.ps1').Replace("'", "''")
$uploadScript = (Join-Path $PSScriptRoot 'Upload-IntuneWin.ps1').Replace("'", "''")
Write-Host 'Review the generated deployment before packaging, then run:'
Write-Host "& '$packageScript' $selection"
Write-Host 'Optional local upload preview (PowerShell 7.2 or later):'
Write-Host "& '$uploadScript' $selection -Preview -AsJson"
Write-Host 'Live upload (PowerShell 7.2 or later): replace <tenant-guid> with your tenant ID.'
Write-Host "& '$uploadScript' $selection -TenantId '<tenant-guid>'"
return [pscustomobject]@{ Status = 'Built'; AppName = $AppName; Version = $Version; Revision = $config.revision; OutputPath = $target; PackagePath = (Join-Path $target 'Package'); InstallCommand = $installCommand; UninstallCommand = $uninstallCommand; RepairCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Repair' }
