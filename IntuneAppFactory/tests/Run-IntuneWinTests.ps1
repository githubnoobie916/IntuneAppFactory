#requires -Version 5.1
[CmdletBinding()]
param([switch]$WithRealTool)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. "$projectRoot/scripts/AppConfig.ps1"
$script:passed = 0
$script:failed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        return
    }
    throw "Expected an error matching: $Pattern"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "FAIL $Name : $_" -ForegroundColor Red }
}

. "$projectRoot/scripts/IntuneWin.ps1"
$sandboxParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Get-FactoryPath $sandboxParent ('IntuneAppFactory.IntuneWinTests-' + [guid]::NewGuid().ToString('N'))
Assert-FactoryNoLinks $sandboxParent
New-Item -ItemType Directory -Path "$sandbox/Package with spaces","$sandbox/v3" -Force | Out-Null
$source = Join-Path $sandbox 'Package with spaces'
# Inert text files test launcher selection only; no launcher or installer is executed.
foreach ($name in @('Invoke-AppDeployToolkit.exe','Invoke-AppDeployToolkit.ps1')) { Set-Content -LiteralPath (Join-Path $source $name) -Value 'Test fixture only' }
foreach ($name in @('Deploy-Application.exe','Deploy-Application.ps1')) { Set-Content -LiteralPath (Join-Path "$sandbox/v3" $name) -Value 'Test fixture only' }
try {
    Test-Case 'PSADT v4 and v3 select their root launcher and a sibling output directory' {
        $v4 = Get-FactoryIntuneWinInputs -SourcePath $source
        $v3 = Get-FactoryIntuneWinInputs -SourcePath "$sandbox/v3"
        Assert-True ($v4.SetupFile -eq 'Invoke-AppDeployToolkit.exe') 'v4 launcher not selected.'
        Assert-True ($v3.SetupFile -eq 'Deploy-Application.exe') 'v3 launcher not selected.'
        Assert-True ($v4.OutputPath -eq (Join-Path $sandbox 'IntuneWin')) 'Default output is not a sibling.'
        Assert-True (-not (Test-Path -LiteralPath $v4.OutputPath)) 'Preflight created output.'
    }
    Test-Case 'Equal, nested, case-aliased and dot-segment output paths are rejected' {
        foreach ($output in @($source, "$source/IntuneWin", "$source/sub/../IntuneWin", "$($source.ToUpperInvariant())/out")) {
            Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source -OutputPath $output } 'outside the source'
        }
        $sibling = Get-FactoryIntuneWinInputs -SourcePath $source -OutputPath ($source + '-output')
        Assert-True ($sibling.OutputPath -eq ($source + '-output')) 'A sibling with a common prefix was rejected.'
    }
    Test-Case 'Missing source, missing script, ambiguous launchers and unsafe overrides fail' {
        Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath "$sandbox/missing" } 'Source directory not found'
        Rename-Item -LiteralPath "$source/Invoke-AppDeployToolkit.ps1" -NewName 'saved.ps1'
        try { Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source } 'companion script' }
        finally { Rename-Item -LiteralPath "$source/saved.ps1" -NewName 'Invoke-AppDeployToolkit.ps1' }
        Copy-Item -LiteralPath "$sandbox/v3/Deploy-Application.exe" -Destination $source
        Copy-Item -LiteralPath "$sandbox/v3/Deploy-Application.ps1" -Destination $source
        try {
            Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source } 'Multiple PSADT launchers'
            $selected = Get-FactoryIntuneWinInputs -SourcePath $source -SetupFile 'Deploy-Application.exe'
            Assert-True ($selected.SetupFile -eq 'Deploy-Application.exe') 'Explicit selection ignored.'
            Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source -SetupFile '../outside.exe' } 'SetupFile'
        }
        finally { Remove-Item -LiteralPath "$source/Deploy-Application.exe","$source/Deploy-Application.ps1" }
    }
    Test-Case 'Previously generated intunewin files cannot leak into a new source archive' {
        Set-Content -LiteralPath "$source/stale.intunewin" -Value 'Old output'
        try { Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source } 'already contains.*intunewin' }
        finally { Remove-Item -LiteralPath "$source/stale.intunewin" }
    }
    Test-Case 'Output junction aliases into the source are rejected' {
        New-Item -ItemType Junction -Path "$sandbox/output-link" -Target $source | Out-Null
        try { Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source -OutputPath "$sandbox/output-link/new" } 'Reparse points' }
        finally { [IO.Directory]::Delete("$sandbox/output-link") }
    }
    Test-Case 'Missing and altered packaging tools fail before execution' {
        Assert-Throws { Get-FactoryIntuneWinTool -ToolPath "$sandbox/missing.exe" } 'Install-IntuneWinTool'
        Set-Content -LiteralPath "$sandbox/altered.exe" -Value 'Not Microsoft code'
        Assert-Throws { Get-FactoryIntuneWinTool -ToolPath "$sandbox/altered.exe" } 'SHA256'
    }
    if ($WithRealTool) {
        Test-Case 'The real Microsoft process returns its exit code and a validated fresh archive' {
            $packaged = New-FactoryIntuneWinPackage -SourcePath $source -OutputPath "$sandbox/real tool output"
            Assert-True ($packaged.Status -eq 'Packaged' -and $packaged.SizeBytes -gt 0) 'Real packaging failed.'
            Assert-True ((Get-FileHash -LiteralPath $packaged.IntuneWinPath).Hash -eq $packaged.SHA256) 'Real output identity mismatch.'
        }
        Test-Case 'A real tool error cannot pass even when Microsoft returns exit code zero' {
            $rejectedOutput = Join-Path $sandbox 'native failure'
            $nativeRunner = (Get-Command Invoke-FactoryIntuneWinProcess).ScriptBlock
            function Invoke-FactoryIntuneWinProcess {
                param($ToolPath,$SourcePath,$SetupFile,$OutputPath,$TimeoutSeconds)
                # Simulate a source becoming unavailable after preflight. Still run
                # Microsoft's real process and preserve its real return value.
                $script:nativeFailureCode = & $nativeRunner -ToolPath $ToolPath -SourcePath "$sandbox/nonexistent-source" -SetupFile $SetupFile -OutputPath $OutputPath -TimeoutSeconds 10
                return $script:nativeFailureCode
            }
            Assert-Throws { New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $rejectedOutput } 'IntuneWin packaging failed'
            Assert-True ($null -ne $script:nativeFailureCode) 'Native failure lost its exit code.'
            Assert-True (-not (Test-Path "$rejectedOutput/Invoke-AppDeployToolkit.intunewin")) 'Invalid input produced an artifact.'
        }
    }
    Test-Case 'The packaging executable and source junctions cannot be included in the source' {
        Set-Content -LiteralPath "$source/IntuneWinAppUtil.exe" -Value 'Unwanted tool copy'
        try { Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source } 'outside the source' }
        finally { Remove-Item -LiteralPath "$source/IntuneWinAppUtil.exe" }
        New-Item -ItemType Junction -Path "$source/linked-payload" -Target "$sandbox/v3" | Out-Null
        try { Assert-Throws { Get-FactoryIntuneWinInputs -SourcePath $source } 'Reparse points' }
        finally { [IO.Directory]::Delete("$source/linked-payload") }
    }
    Test-Case 'Timeout terminates the owned process and releases its handle' {
        $script:fakeProcess = [pscustomobject]@{Killed=$false;Disposed=$false}
        $script:fakeProcess | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $false }
        $script:fakeProcess | Add-Member ScriptMethod Kill { $this.Killed = $true }
        $script:fakeProcess | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        function Start-Process {
            param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
            return $script:fakeProcess
        }
        Assert-Throws { Invoke-FactoryIntuneWinProcess -ToolPath 'stub.exe' -SourcePath $source -SetupFile 'Invoke-AppDeployToolkit.exe' -OutputPath $sandbox -TimeoutSeconds 1 } 'timed out after 1 seconds'
        Assert-True ($script:fakeProcess.Killed -and $script:fakeProcess.Disposed) 'The timed-out process was not terminated/disposed.'
    }
    Test-Case 'Failed or invalid downloads preserve an existing tool and clean staging' {
        $toolDirectory = Join-Path $sandbox 'download test'
        New-Item -ItemType Directory -Path $toolDirectory | Out-Null
        $oldTool = Join-Path $toolDirectory 'IntuneWinAppUtil.exe'
        Set-Content -LiteralPath $oldTool -Value 'Keep the prior bytes until download verification succeeds'
        $oldHash = (Get-FileHash -LiteralPath $oldTool).Hash
        function Invoke-WebRequest {
            param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
            Set-Content -LiteralPath $OutFile -Value 'Incomplete or invalid download'
            if ($script:downloadMode -eq 'transferFailed') { throw 'Simulated interrupted download' }
        }
        foreach ($script:downloadMode in @('badHash','transferFailed')) {
            Assert-Throws { & "$projectRoot/scripts/Install-IntuneWinTool.ps1" -ToolDirectory $toolDirectory -Force } 'SHA256|Simulated interrupted download'
            Assert-True ((Get-FileHash -LiteralPath $oldTool).Hash -eq $oldHash) 'A failed download replaced the old tool.'
            Assert-True (@(Get-ChildItem -LiteralPath $toolDirectory -Force).Count -eq 1) 'Download staging was not cleaned.'
        }
    }
    # Stub only the external executable boundary. These are structural archive fixtures,
    # not deployable packages; the real Microsoft tool is exercised separately end-to-end.
    function Get-FactoryIntuneWinTool { param($ToolPath) return (Join-Path $sandbox 'verified-tool.exe') }
    function Write-TestIntuneWin([string]$Path, [string]$SetupFile) {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($item in @(
                @{Name='IntuneWinPackage/Contents/IntunePackage.intunewin';Text='Structural test fixture'},
                @{Name='IntuneWinPackage/Metadata/Detection.xml';Text="<ApplicationInfo><SetupFile>$SetupFile</SetupFile><FileName>IntunePackage.intunewin</FileName><UnencryptedContentSize>100</UnencryptedContentSize></ApplicationInfo>"}
            )) {
                $writer = New-Object IO.StreamWriter ($archive.CreateEntry($item.Name).Open())
                try { $writer.Write($item.Text) } finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    function Invoke-FactoryIntuneWinProcess {
        param($ToolPath,$SourcePath,$SetupFile,$OutputPath,$TimeoutSeconds)
        Set-Content -LiteralPath (Join-Path $OutputPath 'stdout.log') -Value 'Fixture diagnostic'
        Set-Content -LiteralPath (Join-Path $OutputPath 'stderr.log') -Value 'Fixture error detail'
        $path = Join-Path $OutputPath ([IO.Path]::ChangeExtension($SetupFile, '.intunewin'))
        switch ($script:processMode) {
            'nonzero' { Write-TestIntuneWin $path $SetupFile; return 17 }
            'missing' { return 0 }
            'empty' { [IO.File]::WriteAllBytes($path, [byte[]]@()); return 0 }
            'corrupt' { Set-Content -LiteralPath $path -Value 'Not a zip'; return 0 }
            'wrongsetup' { Write-TestIntuneWin $path 'Deploy-Application.exe'; return 0 }
            'launchfailure' { throw 'Simulated process start failure' }
            default { Write-TestIntuneWin $path $SetupFile; return 0 }
        }
    }
    Test-Case 'App selection packages the same revision as an explicit path from another directory' {
        $script:factory = Join-Path $sandbox "Factory's files"
        $script:revisionPath = Join-Path $factory 'output/Fixture/26.05/rev-01'
        New-Item -ItemType Directory -Path $revisionPath -Force | Out-Null
        Copy-Item -LiteralPath "$projectRoot/scripts" -Destination $factory -Recurse
        Copy-Item -LiteralPath $source -Destination "$revisionPath/Package" -Recurse
        $script:identity = @{factory='IntuneAppFactory';appName='Fixture';version='26.05';revision='01'}
        $identity | ConvertTo-Json | Set-Content "$revisionPath/build.json"
        # Keep real packaging validation; stub only tool verification/execution in the copied factory.
        Add-Content -LiteralPath "$factory/scripts/IntuneWin.ps1" -Value @'
function Get-FactoryIntuneWinTool {
    param($ToolPath)
    $packageProbe.ToolPath = $ToolPath
    return 'verified-test-tool.exe'
}
function Invoke-FactoryIntuneWinProcess {
    param($ToolPath,$SourcePath,$SetupFile,$OutputPath,$TimeoutSeconds)
    $packageProbe.SourcePath = $SourcePath
    $packageProbe.TimeoutSeconds = $TimeoutSeconds
    Set-Content -LiteralPath (Join-Path $OutputPath 'stdout.log') -Value 'Fixture diagnostic'
    Set-Content -LiteralPath (Join-Path $OutputPath 'stderr.log') -Value ''
    Write-TestIntuneWin (Join-Path $OutputPath ([IO.Path]::ChangeExtension($SetupFile, '.intunewin'))) $SetupFile
    return 0
}
'@
        $packageProbe = @{}
        $script:packager = "$factory/scripts/New-IntuneWin.ps1"
        Push-Location $sandbox
        try {
            $selected = & $packager -AppName Fixture -AppVersion 26.05 -Revision '01'
            $explicit = & $packager -SourcePath "$revisionPath/Package" -Force
            Assert-True ($selected.IntuneWinPath -eq $explicit.IntuneWinPath) 'Selection modes resolved different archives.'
            Assert-True ($selected.Status -eq 'Packaged' -and $selected.IntuneWinPath -match 'rev-01') 'Revision or result changed.'
            $custom = & $packager -AppName Fixture -Version 26.05 -Revision '01' -OutputPath "$sandbox/custom output" -ToolPath 'custom-tool.exe' -SetupFile Invoke-AppDeployToolkit.exe -TimeoutSeconds 27 -Force
            Assert-True ($custom.IntuneWinPath -eq (Join-Path $sandbox 'custom output/Invoke-AppDeployToolkit.intunewin')) 'Output override ignored.'
            Assert-True ($packageProbe.ToolPath -eq 'custom-tool.exe' -and $packageProbe.TimeoutSeconds -eq 27) 'Packaging overrides were not forwarded.'
            $legacy = & $packager -SourcePath "$sandbox/v3" -OutputPath "$sandbox/legacy output"
            Assert-True ($legacy.SetupFile -eq 'Deploy-Application.exe') 'Standalone v3 packaging changed.'
        } finally { Pop-Location }
    }
    Test-Case 'App selection requires complete identifiers and rejects mixed parameter sets' {
        $sets = (Get-Command $packager).ParameterSets
        $appSet = @($sets | Where-Object { 'AppName' -in $_.Parameters.Name })
        Assert-True ($appSet.Count -eq 1) 'Expected one app parameter set.'
        foreach ($name in @('AppName','Version','Revision')) {
            Assert-True (@($appSet[0].Parameters | Where-Object { $_.Name -eq $name -and $_.IsMandatory }).Count -eq 1) "$name must be mandatory."
        }
        Assert-Throws { & $packager -AppName Fixture -Version 26.05 -Revision '01' -SourcePath $source } 'parameter set'
        Assert-Throws { & $packager -AppName Fixture -Version 26.05 -Revision '' } 'empty|Revision'
    }
    Test-Case 'Revision resolution rejects missing, unsafe, mismatched and redirected output' {
        $selection = @{ProjectRoot=$factory;AppName='Fixture';Version='26.05';Revision='01'}
        Assert-True ((Resolve-FactoryRevision @selection) -eq [IO.Path]::GetFullPath($revisionPath)) 'Resolver selected the wrong revision.'
        foreach ($bad in @('../outside','CON','bad/name')) {
            $selectionArgs = $selection.Clone(); $selectionArgs.AppName = $bad
            Assert-Throws { Resolve-FactoryRevision @selectionArgs } 'safe path segment'
        }
        $selectionArgs = $selection.Clone(); $selectionArgs.Version = '../outside'
        Assert-Throws { Resolve-FactoryRevision @selectionArgs } 'safe path segment'
        foreach ($bad in @('rev-01','12345','../01',"01`n")) {
            $selectionArgs = $selection.Clone(); $selectionArgs.Revision = $bad
            Assert-Throws { Resolve-FactoryRevision @selectionArgs } 'Revision'
        }
        $selectionArgs = $selection.Clone(); $selectionArgs.Revision = '1'
        Assert-Throws { Resolve-FactoryRevision @selectionArgs } 'Revision directory not found'
        $metadata = "$revisionPath/build.json"
        $saved = Get-Content $metadata -Raw
        try {
            foreach ($field in @('factory','appName','version','revision')) {
                $changed = $identity.Clone(); $changed[$field] = 'wrong'
                $changed | ConvertTo-Json | Set-Content $metadata
                Assert-Throws { Resolve-FactoryRevision @selection } 'metadata|match|IntuneAppFactory'
            }
            foreach ($field in @('factory','appName','version','revision')) {
                $changed = $identity.Clone(); $changed[$field] = @($identity[$field])
                $changed | ConvertTo-Json | Set-Content $metadata
                Assert-Throws { Resolve-FactoryRevision @selection } 'metadata|match|IntuneAppFactory'
            }
            Set-Content $metadata '{bad json'
            Assert-Throws { Resolve-FactoryRevision @selection } 'Invalid.*build.json'
            Remove-Item -LiteralPath $metadata
            Assert-Throws { Resolve-FactoryRevision @selection } 'build.json'
            New-Item -ItemType Junction -Path "$factory/output/Fixture/26.05/rev-02" -Target $revisionPath | Out-Null
            try {
                $selectionArgs = $selection.Clone(); $selectionArgs.Revision = '02'
                Assert-Throws { Resolve-FactoryRevision @selectionArgs } 'Reparse points'
            } finally { [IO.Directory]::Delete("$factory/output/Fixture/26.05/rev-02") }
        } finally { Set-Content $metadata $saved }
    }
    Test-Case 'Nonzero exit, missing, empty and corrupt output never report success' {
        foreach ($mode in @('nonzero','missing','empty','corrupt','wrongsetup','launchfailure')) {
            $script:processMode = $mode
            $output = Join-Path $sandbox $mode
            Assert-Throws { New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $output } 'IntuneWin packaging failed'
            Assert-True (-not (Test-Path "$output/Invoke-AppDeployToolkit.intunewin")) "Published failed $mode output."
            Assert-True (@(Get-ChildItem -LiteralPath $output -Force).Count -eq 0) "Failure left a lock or staging files for $mode."
        }
    }
    Test-Case 'Fresh output is validated; stale output needs Force and survives a failed rebuild' {
        $script:processMode = 'success'
        $output = Join-Path $sandbox 'published'
        $first = New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $output
        Assert-True ($first.Status -eq 'Packaged' -and $first.SizeBytes -gt 0) 'Fresh archive not returned.'
        $hash = (Get-FileHash -LiteralPath $first.IntuneWinPath).Hash
        Assert-True ($first.SHA256 -eq $hash -and $first.SetupFile -eq 'Invoke-AppDeployToolkit.exe') 'Wrong artifact identity.'
        Assert-Throws { New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $output } 'already exists'
        $script:processMode = 'missing'
        Assert-Throws { New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $output -Force } 'IntuneWin packaging failed'
        Assert-True ((Get-FileHash -LiteralPath $first.IntuneWinPath).Hash -eq $hash) 'A stale file was used as success or overwritten.'
        $script:processMode = 'success'
        $rebuilt = New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $output -Force
        Assert-True (Test-Path -LiteralPath $rebuilt.IntuneWinPath) 'Force did not publish the new archive.'
    }
    Test-Case 'Nonzero exit diagnostics are surfaced and output locks block concurrent packaging' {
        $script:processMode = 'nonzero'
        Assert-Throws { New-FactoryIntuneWinPackage -SourcePath $source -OutputPath "$sandbox/diagnostic" } 'exit code 17.*Fixture diagnostic'
        $output = Join-Path $sandbox 'locked'
        New-Item -ItemType Directory -Path $output | Out-Null
        $lockPath = Join-Path $output '.Invoke-AppDeployToolkit.lock'
        $held = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { Assert-Throws { New-FactoryIntuneWinPackage -SourcePath $source -OutputPath $output } 'Cannot acquire packaging lock' }
        finally { $held.Dispose(); Remove-Item -LiteralPath $lockPath }
    }
}
finally {
    $checked = Get-FactoryPath $sandboxParent (Split-Path $sandbox -Leaf)
    if ($checked -ne $sandbox -or (Split-Path $sandbox -Leaf) -notmatch '^IntuneAppFactory\.IntuneWinTests-[0-9a-f]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
Write-Host "IntuneWin tests: $script:passed passed, $script:failed failed. No installers executed."
if ($script:failed) { exit 1 }
