#requires -Version 5.1
<#
.SYNOPSIS
Package an existing PSADT v3 or v4 source directory without executing its deployment.
.DESCRIPTION
Select a generated build with AppName, Version and Revision, or a standalone folder with SourcePath.
App selection resolves apps/<AppName>/<Version>/output/rev-<Revision>/Package relative to the factory directory.
Use SourcePath for existing builds in the old output directory; app selection does not fall back to it.
.PARAMETER AppName
Application directory name under the factory apps directory. Cannot be combined with SourcePath.
.PARAMETER Version
Application version directory; AppVersion is an alias.
.PARAMETER Revision
Required with AppName and Version. Supply the exact 1-4 digit revision, including leading zeros (for example '01').
.PARAMETER SourcePath
Existing PSADT v3/v4 source folder. Does not require factory build metadata.
.PARAMETER OutputPath
Defaults to an IntuneWin directory beside SourcePath. Must be outside SourcePath.
.PARAMETER SetupFile
Root launcher filename. Required only if both v3 and v4 launchers are present.
#>
[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(Mandatory, ParameterSetName='Path')][string]$SourcePath,
    [string]$OutputPath,
    [string]$SetupFile,
    [string]$ToolPath,
    [ValidateRange(1,3600)][int]$TimeoutSeconds = 900,
    [switch]$Force,
    [Parameter(Mandatory, ParameterSetName='App')][string]$AppName,
    [Parameter(Mandatory, ParameterSetName='App')][Alias('AppVersion')][string]$Version,
    [Parameter(Mandatory, ParameterSetName='App')][string]$Revision
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/IntuneWin.ps1"
if ($PSCmdlet.ParameterSetName -eq 'App') {
    $revisionPath = Resolve-FactoryRevision -ProjectRoot (Split-Path $PSScriptRoot -Parent) -AppName $AppName -Version $Version -Revision $Revision
    $SourcePath = Get-FactoryPath $revisionPath 'Package'
}
$packageOptions = @{SourcePath=$SourcePath}
foreach ($name in @(
    'OutputPath','SetupFile','ToolPath','TimeoutSeconds','Force',
    'Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction',
    'ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable'
)) {
    if ($PSBoundParameters.ContainsKey($name)) { $packageOptions[$name] = $PSBoundParameters[$name] }
}
$result = New-FactoryIntuneWinPackage @packageOptions
Write-Host "Packaged: $($result.IntuneWinPath)"
return $result
