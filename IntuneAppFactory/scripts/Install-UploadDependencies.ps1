#requires -Version 7.2
<#
.SYNOPSIS
Install hash-pinned NuGet assemblies for the reference CloudBlockBlob upload client.
.DESCRIPTION
Downloads only from api.nuget.org into tools/BlobClient-11.2.3. The storage SDK is
legacy and unmaintained; retained deliberately to match the working source sample.
Graph authentication is installed separately as documented in UPLOADING.md.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/AppConfig.ps1"
. "$PSScriptRoot/BlobClient.ps1"
$directory = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/BlobClient-11.2.3'
Assert-FactoryNoLinks $directory -Recurse
if (-not $PSCmdlet.ShouldProcess($directory, 'Install pinned Blob client dependencies from NuGet')) { return }
$null = [IO.Directory]::CreateDirectory($directory)
$stage = Join-Path $directory ('.download-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($stage)
try {
    foreach ($package in Get-FactoryBlobDependencies) {
        $id = $package.id.ToLowerInvariant()
        $version = $package.version
        $archivePath = Join-Path $stage "$id.nupkg"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg" -OutFile $archivePath -TimeoutSec 120
        if ((Get-FileHash -LiteralPath $archivePath).Hash -ne $package.packageSha256) { throw "NuGet package hash mismatch: $id $version." }
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        $dllPath = Join-Path $stage "$($package.id).dll"
        try { [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry($package.entry), $dllPath) }
        finally { $archive.Dispose() }
        if ((Get-FileHash -LiteralPath $dllPath).Hash -ne $package.dllSha256) { throw "Assembly hash mismatch: $id." }
    }
    # Nothing is installed until every package and assembly has passed verification.
    foreach ($package in Get-FactoryBlobDependencies) {
        Copy-Item -LiteralPath (Join-Path $stage "$($package.id).dll") -Destination $directory -Force
    }
    Import-FactoryBlobClient
    Write-Host "Verified Blob client dependencies: $directory"
} finally {
    $checked = [IO.Path]::GetFullPath($stage)
    if ((Split-Path $checked -Parent) -ne [IO.Path]::GetFullPath($directory) -or (Split-Path $checked -Leaf) -notmatch '^\.download-[a-f0-9]{32}$') { throw 'Unsafe dependency cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
