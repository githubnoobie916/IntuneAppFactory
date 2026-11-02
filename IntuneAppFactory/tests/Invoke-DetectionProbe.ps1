#requires -Version 5.1
param([string]$ScriptPath, [ValidateSet('Installed','Absent','WrongVersion','WrongProduct','Wow6432')][string]$Scenario)
$ErrorActionPreference = 'Stop'
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($LiteralPath -notmatch '\\\{CD809CD6-9D01-417E-9E76-D19EEE77E74F\}$') { throw 'Detection queried the wrong product GUID.' }
    if ($Scenario -eq 'Absent') { return }
    if ($Scenario -eq 'Wow6432' -and $LiteralPath -notmatch 'WOW6432Node') { return }
    $name = if ($Scenario -eq 'WrongProduct') { 'Different product' } else { 'GlobalProtect' }
    $version = if ($Scenario -eq 'WrongVersion') { '6.2.0' } else { '6.3.3' }
    [pscustomobject]@{DisplayName=$name;DisplayVersion=$version}
}
& $ScriptPath
exit $LASTEXITCODE
