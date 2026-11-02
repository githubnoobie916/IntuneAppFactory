#requires -Version 5.1
<#
.SYNOPSIS
Download and verify the pinned official Microsoft Win32 Content Prep Tool.
.PARAMETER Force
Replace an existing tool only after the new download passes hash and signature checks.
#>
[CmdletBinding()]
param([string]$ToolDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools'), [switch]$Force)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/IntuneWin.ps1"
$ToolDirectory = Resolve-FactoryIntuneWinPath $ToolDirectory
Assert-FactoryNoLinks $ToolDirectory -Recurse
$destination = Get-FactoryPath $ToolDirectory 'IntuneWinAppUtil.exe'
if ((Test-Path -LiteralPath $destination) -and -not $Force) {
    $verified = Get-FactoryIntuneWinTool -ToolPath $destination
    Write-Host "Already verified: $verified"
    return $verified
}
$release = Get-FactoryIntuneWinRelease
$null = [IO.Directory]::CreateDirectory($ToolDirectory)
$stage = Get-FactoryPath $ToolDirectory ('.download-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $stage) { throw 'Download staging path already exists. Retry.' }
$null = [IO.Directory]::CreateDirectory($stage)
$previousProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
    $download = Join-Path $stage 'IntuneWinAppUtil.exe'
    Invoke-WebRequest -Uri $release.DownloadUrl -OutFile $download -UseBasicParsing -TimeoutSec 120
    $null = Get-FactoryIntuneWinTool -ToolPath $download
    $signature = Get-AuthenticodeSignature -LiteralPath $download
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Downloaded tool does not have a valid Microsoft Authenticode signature: $($signature.Status)."
    }
    $licenseName = 'Microsoft License Terms For Win32 Content Prep Tool.pdf'
    Invoke-WebRequest -Uri $release.LicenseUrl -OutFile (Join-Path $stage $licenseName) -UseBasicParsing -TimeoutSec 120
    $receipt = [ordered]@{
        version = $release.Version; repository = $release.Repository; commit = $release.Commit
        downloadUrl = $release.DownloadUrl; sha256 = $release.SHA256
        signatureStatus = [string]$signature.Status; signer = $signature.SignerCertificate.Subject
        downloadedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'IntuneWinAppUtil.provenance.json') -Encoding UTF8
    foreach ($name in @($licenseName, 'IntuneWinAppUtil.provenance.json')) {
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $ToolDirectory $name) -Force
    }
    Assert-FactoryNoLinks $destination
    if ((Test-Path -LiteralPath $destination) -and $Force) { [IO.File]::Replace($download, $destination, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($download, $destination) }
    Write-Host "Verified Microsoft Win32 Content Prep Tool $($release.Version): $destination"
    return $destination
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    $checked = Get-FactoryPath $ToolDirectory (Split-Path $stage -Leaf)
    if ($checked -ne $stage -or (Split-Path $stage -Leaf) -notmatch '^\.download-[0-9a-f]{32}$') { throw 'Unsafe download cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
