#requires -Version 5.1
# Build-time helpers only. Never copied into the deployment Package.
. "$PSScriptRoot/AppConfig.ps1"

function Get-FactoryIntuneWinRelease {
    # Official v1.8.7 tag, resolved to its immutable commit. Hash checked on every use.
    return [pscustomobject]@{
        Version = '1.8.7'
        Repository = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool'
        Commit = '1d6cfcbdf8c28edc596337031f74df951f38f718'
        SHA256 = 'C1BA45B5CB939E84AF064BB7FF4B38FB3DFE33C8DC1078FD9B157672EAE671F6'
        DownloadUrl = 'https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/1d6cfcbdf8c28edc596337031f74df951f38f718/IntuneWinAppUtil.exe'
        LicenseUrl = 'https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/1d6cfcbdf8c28edc596337031f74df951f38f718/Microsoft%20License%20Terms%20For%20Win32%20Content%20Prep%20Tool.pdf'
    }
}

function Resolve-FactoryIntuneWinPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A filesystem path is required.' }
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) { throw 'A drive or share root cannot be used for packaging.' }
    # Reuse the factory rules for device names, ADS, wildcards and Windows aliases.
    return Get-FactoryPath $root $full.Substring($root.Length).TrimEnd('\', '/')
}

function Assert-FactoryIntuneWinOutsideSource([string]$SourcePath, [string]$Path, [string]$Label) {
    if ($Path.Equals($SourcePath, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($SourcePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be outside the source directory: '$SourcePath'."
    }
}

function Get-FactoryIntuneWinTool([string]$ToolPath) {
    if (-not $ToolPath) { $ToolPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/IntuneWinAppUtil.exe' }
    $ToolPath = Resolve-FactoryIntuneWinPath $ToolPath
    Assert-FactoryNoLinks $ToolPath
    if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) {
        throw "IntuneWinAppUtil.exe not found: '$ToolPath'. Run scripts/Install-IntuneWinTool.ps1 first."
    }
    $release = Get-FactoryIntuneWinRelease
    if ((Get-FileHash -LiteralPath $ToolPath -Algorithm SHA256).Hash -ne $release.SHA256) {
        throw "IntuneWinAppUtil.exe SHA256 does not match the pinned official Microsoft release $($release.Version): '$ToolPath'."
    }
    return $ToolPath
}

function Get-FactoryIntuneWinInputs([string]$SourcePath, [string]$OutputPath, [string]$SetupFile) {
    $SourcePath = Resolve-FactoryIntuneWinPath $SourcePath
    Assert-FactoryNoLinks $SourcePath -Recurse
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw "Source directory not found: '$SourcePath'." }
    if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path $SourcePath -Parent) 'IntuneWin' }
    $OutputPath = Resolve-FactoryIntuneWinPath $OutputPath
    Assert-FactoryNoLinks $OutputPath -Recurse
    Assert-FactoryIntuneWinOutsideSource $SourcePath $OutputPath 'Output directory'
    if ((Test-Path -LiteralPath $OutputPath) -and -not (Test-Path -LiteralPath $OutputPath -PathType Container)) { throw "Output is not a directory: '$OutputPath'." }
    $launchers = @('Invoke-AppDeployToolkit.exe', 'Deploy-Application.exe')
    if ($SetupFile) {
        if ($SetupFile -notin $launchers) { throw 'SetupFile must be Invoke-AppDeployToolkit.exe (v4) or Deploy-Application.exe (v3), at the source root.' }
    }
    else {
        $found = @($launchers | Where-Object { Test-Path -LiteralPath (Join-Path $SourcePath $_) -PathType Leaf })
        if ($found.Count -eq 0) { throw 'No PSADT setup launcher found at the source root.' }
        if ($found.Count -gt 1) { throw 'Multiple PSADT launchers found; select one with -SetupFile.' }
        $SetupFile = $found[0]
    }
    foreach ($required in @($SetupFile, [IO.Path]::ChangeExtension($SetupFile, '.ps1'))) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourcePath $required) -PathType Leaf)) { throw "PSADT launcher or companion script missing: '$required'." }
    }
    if (@(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force -Filter '*.intunewin').Count) {
        throw 'Source already contains .intunewin output. Remove that output from the source before packaging.'
    }
    if (@(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force -Filter 'IntuneWinAppUtil.exe').Count) {
        throw 'Keep IntuneWinAppUtil.exe outside the source directory.'
    }
    return [pscustomobject]@{ SourcePath = $SourcePath; OutputPath = $OutputPath; SetupFile = $SetupFile }
}

function Invoke-FactoryIntuneWinProcess {
    param([string]$ToolPath, [string]$SourcePath, [string]$SetupFile, [string]$OutputPath, [int]$TimeoutSeconds)
    # Validated paths cannot contain quotes or end in a backslash. Quote each value
    # for Windows PowerShell 5.1 as well as PS7; do not use a shell or Invoke-Expression.
    $arguments = '-c "{0}" -s "{1}" -o "{2}" -q' -f $SourcePath, $SetupFile, $OutputPath
    $process = Start-Process -FilePath $ToolPath -ArgumentList $arguments -WorkingDirectory $OutputPath -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $OutputPath 'stdout.log') -RedirectStandardError (Join-Path $OutputPath 'stderr.log')
    try {
        # Retain the native handle before waiting; otherwise Windows PowerShell 5.1
        # can lose ExitCode for a process started with -PassThru without -Wait.
        $null = $process.Handle
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $null = $process.WaitForExit(5000)
            throw "IntuneWinAppUtil timed out after $TimeoutSeconds seconds."
        }
        $process.WaitForExit() # Finish draining redirected output before reading logs.
        $process.Refresh()
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

function Assert-FactoryIntuneWinArchive([string]$Path, [string]$SetupFile) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw 'The expected nonempty .intunewin file was not produced.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $payload = $archive.GetEntry('IntuneWinPackage/Contents/IntunePackage.intunewin')
        $metadata = $archive.GetEntry('IntuneWinPackage/Metadata/Detection.xml')
        if (-not $payload -or $payload.Length -eq 0 -or -not $metadata -or $metadata.Length -eq 0 -or $metadata.Length -gt 1MB) {
            throw 'Invalid .intunewin archive: encrypted content or detection metadata is missing/invalid.'
        }
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.CloseInput = $true
        $reader = [Xml.XmlReader]::Create($metadata.Open(), $settings)
        try {
            $document = New-Object Xml.XmlDocument
            $document.XmlResolver = $null
            $document.Load($reader)
        }
        finally { $reader.Dispose() }
        $contentSize = 0L
        if ($document.ApplicationInfo.SetupFile -cne $SetupFile -or
            $document.ApplicationInfo.FileName -cne 'IntunePackage.intunewin' -or
            -not [long]::TryParse($document.ApplicationInfo.UnencryptedContentSize, [ref]$contentSize) -or $contentSize -le 0) {
            throw 'Invalid .intunewin detection metadata: setup filename or content size does not match.'
        }
    }
    finally { $archive.Dispose() }
}

function New-FactoryIntuneWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$OutputPath,
        [string]$SetupFile,
        [string]$ToolPath,
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 900,
        [switch]$Force
    )
    $inputPaths = Get-FactoryIntuneWinInputs -SourcePath $SourcePath -OutputPath $OutputPath -SetupFile $SetupFile
    $ToolPath = Get-FactoryIntuneWinTool -ToolPath $ToolPath
    Assert-FactoryIntuneWinOutsideSource $inputPaths.SourcePath $ToolPath 'Packaging tool'
    $baseName = [IO.Path]::GetFileNameWithoutExtension($inputPaths.SetupFile)
    $fileName = $baseName + '.intunewin'
    $destination = Get-FactoryPath $inputPaths.OutputPath $fileName
    if ((Test-Path -LiteralPath $destination) -and -not $Force) { throw "IntuneWin output already exists: '$destination'. Use -Force to replace it." }
    $null = [IO.Directory]::CreateDirectory($inputPaths.OutputPath)
    $work = Get-FactoryPath $inputPaths.OutputPath ('.intunewin-' + [guid]::NewGuid().ToString('N'))
    $lockPath = Get-FactoryPath $inputPaths.OutputPath ('.' + $baseName + '.lock')
    Assert-FactoryNoLinks $lockPath
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch { throw "Cannot acquire packaging lock '$lockPath'. Another packaging run may be active; inspect stale locks before removing them." }
    $ownsWork = $false
    try {
        if ((Test-Path -LiteralPath $destination) -and -not $Force) { throw "IntuneWin output already exists: '$destination'." }
        if (Test-Path -LiteralPath $work) { throw 'Temporary packaging path already exists. Retry packaging.' }
        $null = [IO.Directory]::CreateDirectory($work)
        $ownsWork = $true
        $exitCode = Invoke-FactoryIntuneWinProcess -ToolPath $ToolPath -SourcePath $inputPaths.SourcePath -SetupFile $inputPaths.SetupFile -OutputPath $work -TimeoutSeconds $TimeoutSeconds
        if ($null -eq $exitCode -or $exitCode -ne 0) { throw "IntuneWinAppUtil failed with exit code $exitCode." }
        $created = Get-FactoryPath $work $fileName
        if (@(Get-ChildItem -LiteralPath $work -File -Filter '*.intunewin').Count -ne 1) { throw 'Expected exactly one new .intunewin file.' }
        Assert-FactoryIntuneWinArchive -Path $created -SetupFile $inputPaths.SetupFile
        $hash = (Get-FileHash -LiteralPath $created -Algorithm SHA256).Hash
        $size = (Get-Item -LiteralPath $created).Length
        foreach ($stream in @('stdout','stderr')) {
            Copy-Item -LiteralPath (Join-Path $work "$stream.log") -Destination (Join-Path $inputPaths.OutputPath "$baseName.$stream.log") -Force
        }
        Assert-FactoryNoLinks $destination
        # Publish only the newly validated file, preserving the old archive on failure.
        if ((Test-Path -LiteralPath $destination) -and $Force) { [IO.File]::Replace($created, $destination, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($created, $destination) }
        return [pscustomobject]@{
            Status = 'Packaged'; IntuneWinPath = $destination; SetupFile = $inputPaths.SetupFile
            SizeBytes = $size; SHA256 = $hash; ToolVersion = (Get-FactoryIntuneWinRelease).Version
        }
    }
    catch {
        $details = @()
        if ($ownsWork) {
            foreach ($stream in @('stdout','stderr')) {
                $log = Join-Path $work "$stream.log"
                if (Test-Path -LiteralPath $log -PathType Leaf) { $details += Get-Content -LiteralPath $log -Tail 12 }
            }
        }
        throw "IntuneWin packaging failed: $($_.Exception.Message) $($details -join ' ')"
    }
    finally {
        try {
            if ($ownsWork) {
                $checked = Get-FactoryPath $inputPaths.OutputPath (Split-Path $work -Leaf)
                if ($checked -ne $work -or (Split-Path $work -Leaf) -notmatch '^\.intunewin-[0-9a-f]{32}$') { throw 'Unsafe packaging cleanup path.' }
                Assert-FactoryNoLinks $checked -Recurse
                Remove-Item -LiteralPath $checked -Recurse -Force
            }
        }
        finally { $lock.Dispose(); Remove-Item -LiteralPath $lockPath -Force }
    }
}
