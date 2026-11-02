#requires -Version 5.1
<#
.SYNOPSIS
Package an existing PSADT v3 or v4 source directory without executing its deployment.
.PARAMETER OutputPath
Defaults to an IntuneWin directory beside SourcePath. Must be outside SourcePath.
.PARAMETER SetupFile
Root launcher filename. Required only if both v3 and v4 launchers are present.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [string]$OutputPath,
    [string]$SetupFile,
    [string]$ToolPath,
    [ValidateRange(1,3600)][int]$TimeoutSeconds = 900,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/IntuneWin.ps1"
$result = New-FactoryIntuneWinPackage @PSBoundParameters
Write-Host "Packaged: $($result.IntuneWinPath)"
return $result
