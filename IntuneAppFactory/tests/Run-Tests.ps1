#requires -Version 5.1
[CmdletBinding()]
param([switch]$WithRealTool)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. "$projectRoot/scripts/AppConfig.ps1"
. "$PSScriptRoot/Invoke-DeploymentProbe.ps1"
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
    catch { $script:failed++; Write-Host "FAIL $Name : $_`n$($_.ScriptStackTrace)" -ForegroundColor Red }
}
function New-TestConfig { Get-Content "$projectRoot/apps/7zip/26.05/app.json" -Raw | ConvertFrom-Json }
function Save-TestConfig($Config) { $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8 }
function Get-TreeSnapshot([string]$Root) {
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Root.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n")
}
$sandboxParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Get-FactoryPath $sandboxParent ('IntuneAppFactory.Tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$configPath = Join-Path $sandbox 'app.json'
try {
    Test-Case 'OneDrive metadata is accepted while directory junctions are rejected' {
        Assert-FactoryNoLinks $projectRoot
        $cloudPath = Join-Path $sandbox 'cloud-placeholder'
        New-Item -ItemType Directory $cloudPath | Out-Null
        function Get-Item {
            [CmdletBinding()]param($LiteralPath,[switch]$Force)
            if ($LiteralPath -eq $cloudPath) {
                return [pscustomobject]@{FullName=$cloudPath;Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint);LinkType=$null}
            }
            Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
        }
        Assert-FactoryNoLinks $cloudPath
        New-Item -ItemType Junction -Path "$sandbox/junction" -Target $cloudPath | Out-Null
        try { Assert-Throws { Assert-FactoryNoLinks "$sandbox/junction/child" } 'Reparse points' }
        finally { [IO.Directory]::Delete("$sandbox/junction") }
    }
    Test-Case 'Complete explicit configuration supports repair and described processes' {
        Save-TestConfig (New-TestConfig)
        $config = Read-FactoryConfig $configPath
        Assert-True ($config.repair.Count -eq 0 -and $config.psadt.processesToClose[0].description -eq '7-Zip File Manager') 'Explicit settings were not retained.'
    }
    Test-Case 'Deployment mode belongs to the launcher and is rejected in JSON' {
        $config = New-TestConfig
        $config.psadt.PSObject.Properties.Remove('deployMode')
        Save-TestConfig $config
        $null = Read-FactoryConfig $configPath
        $config.psadt | Add-Member deployMode 'Silent'
        Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'Unknown property.*deployMode'
    }
    Test-Case 'Optional upload JSON validates while legacy configuration stays supported' {
        $example = Get-Content "$projectRoot/examples/notepadplusplus.app.json" -Raw | ConvertFrom-Json
        Save-TestConfig $example
        $actual = Read-FactoryConfig $configPath
        Assert-True ($actual.intune.upload.returnCodes.Count -eq 4 -and $actual.intune.detection.operationType -eq 'version') 'Explicit upload configuration was lost.'
        $example.intune.PSObject.Properties.Remove('upload')
        $example.intune.PSObject.Properties.Remove('informationUrl')
        Save-TestConfig $example
        $null = Read-FactoryConfig $configPath
    }
    Test-Case 'Invalid upload fields, transport limits, return codes and detection operators are rejected' {
        foreach ($change in @(
            { param($c) $c.intune.upload.transport.maxRetries = -1 },
            { param($c) $c.intune.upload.transport.blockSizeBytes = 0 },
            { param($c) $c.intune.upload.transport.timeoutSeconds = '900' },
            { param($c) $c.intune.upload.transport.sasRenewalThresholdMinutes = 0 },
            { param($c) $c.intune.upload.returnCodes += $c.intune.upload.returnCodes[0] },
            { param($c) $c.intune.upload.returnCodes[0].type = 'ignore' },
            { param($c) $c.intune.upload.returnCodes[0].returnCode = '0' },
            { param($c) $c.intune.upload | Add-Member clientSecret 'must-not-be-stored' },
            { param($c) $c.intune.upload.restartBehavior = 'never' },
            { param($c) $c.intune.upload.PSObject.Properties.Remove('deployMode') },
            { param($c) $c.intune.informationUrl = 'file:///C:/test' },
            { param($c) $c.intune.detection.check32BitOn64System = 'false' },
            { param($c) $c.intune.detection.value = 'not a version' },
            { param($c) $c.intune.detection.operator = 'notConfigured' },
            { param($c) $c.intune.detection.PSObject.Properties.Remove('operator') }
        )) {
            $example = Get-Content "$projectRoot/examples/notepadplusplus.app.json" -Raw | ConvertFrom-Json
            & $change $example
            Save-TestConfig $example
            Assert-Throws { Read-FactoryConfig $configPath } 'upload|Registry|informationUrl'
        }
    }
    Test-Case 'Every root and deployment setting is required even when disabled' {
        foreach ($section in @('root','psadt','completionPrompt','intune')) {
            $original = New-TestConfig
            $settings = switch ($section) { root { $original }; psadt { $original.psadt }; completionPrompt { $original.psadt.completionPrompt }; intune { $original.intune } }
            foreach ($name in @($settings.PSObject.Properties.Name)) {
                $config = New-TestConfig
                $target = switch ($section) { root { $config }; psadt { $config.psadt }; completionPrompt { $config.psadt.completionPrompt }; intune { $config.intune } }
                $target.PSObject.Properties.Remove($name)
                Save-TestConfig $config
                Assert-Throws { Read-FactoryConfig $configPath } ([regex]::Escape(".$name"))
            }
        }
    }
    Test-Case 'Arguments must be explicit for MSI and EXE across all three actions' {
        foreach ($action in @('install','uninstall','repair')) {
            foreach ($type in @('MSI','EXE')) {
                $config = New-TestConfig
                $config.$action = @([pscustomobject]@{type=$type;path="setup.$($type.ToLowerInvariant())"})
                Save-TestConfig $config
                Assert-Throws { Read-FactoryConfig $configPath } "app\.$action\[0\]\.arguments"
            }
        }
    }
    Test-Case 'Multiple described processes are accepted and incomplete or duplicate entries rejected' {
        $config = New-TestConfig
        $config.psadt.processesToClose += [pscustomobject]@{name='7zG';description='7-Zip GUI'}
        Save-TestConfig $config
        Assert-True ((Read-FactoryConfig $configPath).psadt.processesToClose.Count -eq 2) 'Multiple processes rejected.'
        $config.psadt.processesToClose[1].PSObject.Properties.Remove('description')
        Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'description'
        $config.psadt.processesToClose[1] = [pscustomobject]@{name='7ZFM';description='Duplicate'}
        Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'duplicate'
    }
    Test-Case 'Repair accepts MSI product codes and installed EXE paths' {
        $config = New-TestConfig
        $config.repair = @(
            [pscustomobject]@{type='MSI';productCode='{12345678-1234-1234-1234-123456789012}';arguments='/qn REINSTALL=ALL REINSTALLMODE=omus'},
            [pscustomobject]@{type='EXE';executable='%ProgramFiles%\Example\setup.exe';arguments='/repair /quiet'}
        )
        Save-TestConfig $config
        Assert-True ((Read-FactoryConfig $configPath).repair.Count -eq 2) 'Repair selectors rejected.'
    }
    Test-Case 'Pristine template renders native actions without runtime factory dependencies' {
        . "$projectRoot/scripts/Update-DeploymentTemplate.ps1"
        $source = Join-Path (Split-Path $projectRoot -Parent) 'sources/PSAppDeployToolkit_Template_v4/Invoke-AppDeployToolkit.ps1'
        $sourceHash = (Get-FileHash $source).Hash
        $entry = Join-Path $sandbox 'Invoke-AppDeployToolkit.ps1'
        Copy-Item -LiteralPath $source -Destination $entry
        $config = New-TestConfig
        $config.repair = @([pscustomobject]@{type='EXE';path='repair.exe';arguments='/repair /quiet'})
        Update-FactoryDeploymentTemplate -Path $entry -Config $config
        $generated = Get-Content $entry -Raw
        Assert-True ($generated.Contains('Start-ADTMsiProcess -Action Install') -and $generated.Contains('Start-ADTMsiProcess -Action Uninstall') -and $generated.Contains("'repair.exe'")) 'Direct action commands missing.'
        Assert-True ($generated -notmatch 'Invoke-Factory|Read-Factory|SupportFiles[/\\]Factory|app\.json|\{\{AppName\}\}') 'Generated script has factory runtime dependencies.'
        Assert-True ((Get-FileHash $source).Hash -eq $sourceHash) 'Original template changed.'
        $parseTokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$parseTokens, [ref]$parseErrors)
        Assert-True (-not $parseErrors) 'Generated syntax is invalid.'
    }
    Test-Case 'Builder uses original template and creates a standalone package without packaging tools' {
        $script:fixtureRoot = Join-Path $sandbox 'Factory'
        New-Item -ItemType Directory -Path "$fixtureRoot/apps/Fixture/26.05/installers","$sandbox/sources" -Force | Out-Null
        Copy-Item -LiteralPath "$projectRoot/scripts" -Destination $fixtureRoot -Recurse
        $script:pristineRoot = Join-Path (Split-Path $projectRoot -Parent) 'sources/PSAppDeployToolkit_Template_v4'
        Copy-Item -LiteralPath $pristineRoot -Destination "$sandbox/sources" -Recurse
        $config = New-TestConfig
        $config.psadt.scriptAuthor = 'Test author'
        $config.intune.icon = ''
        $config.install += [pscustomobject]@{type='EXE';path='setup.exe';arguments='/quiet'}
        $config.repair = @([pscustomobject]@{type='EXE';path='repair.exe';arguments='/repair'})
        $config | ConvertTo-Json -Depth 20 | Set-Content "$fixtureRoot/apps/Fixture/26.05/app.json" -Encoding UTF8
        foreach ($name in @('7z2605-x64.msi','setup.exe','repair.exe')) { Set-Content "$fixtureRoot/apps/Fixture/26.05/installers/$name" 'Inert test payload; never execute.' }
        $script:builder = "$fixtureRoot/scripts/Build-App.ps1"
        Push-Location $sandbox
        try { $script:built = & $builder -AppName Fixture -Version 26.05 }
        finally { Pop-Location }
        Assert-True (Test-Path "$($built.PackagePath)/Files/repair.exe") 'Repair-only payload was not copied.'
        Assert-True (-not (Test-Path "$($built.PackagePath)/app.json") -and -not (Test-Path "$($built.PackagePath)/SupportFiles/Factory")) 'Runtime factory files were shipped.'
        Assert-True (Test-Path "$($built.OutputPath)/app.json") 'Build configuration snapshot missing.'
        Assert-True (-not (Test-Path "$($built.OutputPath)/IntuneWin")) 'Builder performed packaging.'
        foreach ($file in Get-ChildItem -LiteralPath $pristineRoot -File -Recurse -Force) {
            $relative = $file.FullName.Substring($pristineRoot.Length + 1)
            if ($relative -eq 'Invoke-AppDeployToolkit.ps1') { continue }
            Assert-True ((Get-FileHash $file.FullName).Hash -eq (Get-FileHash (Join-Path $built.PackagePath $relative)).Hash) "Template file changed: $relative"
        }
    }
    Test-Case 'Builder snapshots detection script bytes without executing them or including them in Package' {
        $appConfigPath = "$fixtureRoot/apps/Fixture/26.05/app.json"
        $originalConfig = Get-Content $appConfigPath -Raw
        $scriptPath = "$fixtureRoot/apps/Fixture/26.05/Detect.ps1"
        try {
            $config = $originalConfig | ConvertFrom-Json
            $config.intune.detection = [pscustomobject]@{type='powershell';scriptPath='Detect.ps1';runAs32Bit=$false;enforceSignatureCheck=$false}
            $config | ConvertTo-Json -Depth 20 | Set-Content $appConfigPath -Encoding UTF8
            $scriptBytes = [byte[]](@(239,187,191) + [Text.Encoding]::UTF8.GetBytes('throw "Detection must never execute during generation"'))
            [IO.File]::WriteAllBytes($scriptPath, $scriptBytes)
            $scriptBuild = & $builder -AppName Fixture -Version 26.05 -Revision '88'
            $snapshot = Join-Path $scriptBuild.OutputPath 'Detection/Detect.ps1'
            $metadata = Get-Content (Join-Path $scriptBuild.OutputPath 'build.json') -Raw | ConvertFrom-Json
            Assert-True ((Get-FileHash $snapshot).Hash -eq (Get-FileHash $scriptPath).Hash) 'Detection bytes changed.'
            Assert-True ($metadata.detectionScript.sha256 -eq (Get-FileHash $snapshot).Hash) 'Snapshot hash mismatch.'
            Assert-True (-not (Test-Path (Join-Path $scriptBuild.PackagePath 'Detection'))) 'Detection script is in the installer package.'
            Set-Content $scriptPath 'exit 1'
            Assert-True ((Get-FileHash $snapshot).Hash -eq $metadata.detectionScript.sha256) 'Source changes affected existing revision.'
            Remove-Item $scriptPath
            Assert-Throws { & $builder -AppName Fixture -Version 26.05 -Revision '89' } 'not found'
            Assert-True (-not (Test-Path "$fixtureRoot/output/Fixture/26.05/rev-89")) 'Missing script left output.'
        } finally { Set-Content $appConfigPath $originalConfig -Encoding UTF8 }
    }
    Test-Case 'Detection script validation rejects empty, invalid UTF-8 and invalid PowerShell without executing' {
        $scriptPath = Join-Path $sandbox 'invalid-detection.ps1'
        foreach ($case in @(
            @{bytes=[byte[]]@();pattern='empty'},
            @{bytes=[byte[]]@(255,254,0);pattern='UTF-8'},
            @{bytes=[Text.Encoding]::UTF8.GetBytes('if (');pattern='syntax errors'}
        )) {
            [IO.File]::WriteAllBytes($scriptPath, $case.bytes)
            Assert-Throws { Read-FactoryDetectionScript $scriptPath } $case.pattern
        }
    }
    Test-Case 'Detached package executes install, uninstall and repair without factory files' {
        $script:detached = Join-Path $sandbox 'Detached package'
        Copy-Item -LiteralPath $built.PackagePath -Destination $detached -Recurse
        foreach ($action in @('Install','Uninstall','Repair')) {
            $state = Invoke-DeploymentProbe $detached @{DeploymentType=$action}
            $expected = if ($action -eq 'Install') { 2 } else { 1 }
            Assert-True ($state.Calls.Count -eq $expected -and $state.ExitCodes.Count -eq 1 -and $state.ExitCodes[0] -eq 0) "Failed $action lifecycle."
            Assert-True ($state.Session.InstallPhase -eq "Post-$action") 'Original phases were lost.'
            Assert-True ($state.Opened.AppName -eq '7-Zip' -and -not $state.Opened.ContainsKey('DeployMode')) 'Metadata missing or generator supplied a deployment mode.'
            Assert-True ($state.Calls[0].FilePath.StartsWith($detached)) 'Detached package used a repository path.'
            Assert-True ($state.Imports.Count -eq 2 -and $state.Imports[0].StartsWith($detached)) 'Local module/extension imports were lost.'
            Assert-True ($state.Prompts.Count -eq 0) 'Disabled completion prompt was displayed.'
        }
        $failed = Invoke-DeploymentProbe $detached @{DeploymentType='Install'} -FailProcess
        Assert-True ($failed.Calls.Count -eq 1 -and $failed.ExitCodes[0] -eq 60001 -and $failed.Errors.Count -eq 1) 'Failed step did not stop deployment and use native error handling.'
    }
    Test-Case 'Every explicit launcher mode reaches the native session unchanged' {
        foreach ($mode in @('Auto','Interactive','NonInteractive','Silent')) {
            $state = Invoke-DeploymentProbe $detached @{DeploymentType='Install';DeployMode=$mode}
            Assert-True ($state.ExitCodes[0] -eq 0 -and $state.Opened.DeployMode -eq $mode) "Launcher mode $mode was lost."
        }
    }
    Test-Case 'Described processes, deferrals and completion prompt use JSON and CLI overrides' {
        $config = New-TestConfig
        $config.psadt.processesToClose += [pscustomobject]@{name='7zG';description='7-Zip GUI'}
        $config.psadt.closeProcesses = $true
        $config.psadt.closeProcessesCountdown = 123
        $config.psadt.allowDefer = $true
        $config.psadt.deferTimes = 7
        $config.psadt.suppressRebootPassThru = $true
        $config.psadt.terminalServerMode = $true
        $config.psadt.disableLogging = $true
        $config.psadt.checkDiskSpace = $false
        $config.psadt.persistPrompt = $false
        $config.psadt.completionPrompt.enabled = $true
        $config.psadt.completionPrompt.message = "Installation's complete."
        $config.psadt.completionPrompt.noWait = $false
        Copy-Item "$pristineRoot/Invoke-AppDeployToolkit.ps1" "$detached/Invoke-AppDeployToolkit.ps1" -Force
        . "$projectRoot/scripts/Update-DeploymentTemplate.ps1"
        Update-FactoryDeploymentTemplate "$detached/Invoke-AppDeployToolkit.ps1" $config
        $state = Invoke-DeploymentProbe $detached @{DeployMode='Interactive'}
        Assert-True ($state.Opened.AppProcessesToClose.Count -eq 2 -and $state.Opened.AppProcessesToClose[1].Description -eq '7-Zip GUI') 'Process descriptions were lost.'
        $welcome = $state.Welcome[0]
        Assert-True ($welcome.CloseProcessesCountdown -eq 123 -and $welcome.AllowDefer -and $welcome.DeferTimes -eq 7 -and -not $welcome.CheckDiskSpace -and -not $welcome.PersistPrompt) 'Welcome options differ from JSON.'
        Assert-True ($state.Prompts.Count -eq 1 -and $state.Prompts[0].Message -eq "Installation's complete." -and -not $state.Prompts[0].NoWait) 'Completion prompt differs from JSON.'
        foreach ($action in @('Uninstall','Repair')) {
            $state = Invoke-DeploymentProbe $detached @{DeploymentType=$action}
            Assert-True ($state.Welcome.Count -eq 1 -and $state.Welcome[0].CloseProcessesCountdown -eq 123 -and -not $state.Welcome[0].AllowDefer) 'Uninstall/repair must close configured processes without deferrals.'
        }
        $state = Invoke-DeploymentProbe $detached @{DeployMode='Silent';SuppressRebootPassThru=$false;TerminalServerMode=$false;DisableLogging=$false}
        Assert-True ($state.Opened.DeployMode -eq 'Silent' -and -not $state.Welcome[0].AllowDefer -and -not $state.Opened.SuppressRebootPassThru -and -not $state.Opened.TerminalServerMode -and -not $state.Opened.DisableLogging) 'Explicit CLI overrides were ignored.'
    }
    Test-Case 'Arguments stay literal and MSI repair and installed EXE selectors work' {
        . "$projectRoot/scripts/Update-DeploymentTemplate.ps1"
        $config = New-TestConfig
        $script:literalArguments = '/quiet "O''Brien" $env:TEMP $(throw ''injection'') `tick {{AppName}} ## <Perform Repair tasks here>'
        $config.install[0].arguments = $literalArguments
        $config.repair = @(
            [pscustomobject]@{type='MSI';productCode='{12345678-1234-1234-1234-123456789012}';arguments='/qn /norestart'},
            [pscustomobject]@{type='EXE';executable='%ProgramFiles%\Example\repair.exe';arguments='/repair /quiet'},
            [pscustomobject]@{type='EXE';path='noargs.exe';arguments=''}
        )
        Copy-Item "$pristineRoot/Invoke-AppDeployToolkit.ps1" "$detached/Invoke-AppDeployToolkit.ps1" -Force
        Update-FactoryDeploymentTemplate "$detached/Invoke-AppDeployToolkit.ps1" $config
        $state = Invoke-DeploymentProbe $detached
        Assert-True ($state.Calls[0].ArgumentList[0] -ceq $literalArguments) 'Arguments were evaluated or replaced again.'
        $state = Invoke-DeploymentProbe $detached @{DeploymentType='Repair'}
        Assert-True ($state.ExitCodes[0] -eq 0 -and $state.Calls.Count -eq 3 -and $state.Calls[0].Action -eq 'Repair' -and $state.Calls[0].RepairMode -eq 'Repair') 'MSI repair behavior is wrong.'
        Assert-True ($state.Calls[0].ProductCode -eq $config.repair[0].productCode -and $state.Calls[1].FilePath -eq "$env:ProgramFiles\Example\repair.exe") 'Repair targets are wrong.'
        Assert-True (-not $state.Calls[2].ContainsKey('ArgumentList')) 'Explicit empty EXE arguments should invoke with no arguments.'
    }
    Test-Case 'Template changes fail before writing and original comments and parameters survive' {
        . "$projectRoot/scripts/Update-DeploymentTemplate.ps1"
        $entry = "$detached/Invoke-AppDeployToolkit.ps1"
        $original = Get-Content "$pristineRoot/Invoke-AppDeployToolkit.ps1" -Raw
        $original.Replace('## <Perform Repair tasks here>', '## unexpected marker') | Set-Content $entry -Encoding UTF8
        $before = (Get-FileHash $entry).Hash
        Assert-Throws { Update-FactoryDeploymentTemplate $entry (New-TestConfig) } 'Unexpected template structure'
        Assert-True ((Get-FileHash $entry).Hash -eq $before) 'Failed rendering changed the input.'
        Copy-Item "$pristineRoot/Invoke-AppDeployToolkit.ps1" $entry -Force
        Update-FactoryDeploymentTemplate $entry (New-TestConfig)
        $sourceTokens=$null; $renderTokens=$null; $errors=$null
        $sourceAst = [Management.Automation.Language.Parser]::ParseInput($original, [ref]$sourceTokens, [ref]$errors)
        $renderAst = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$renderTokens, [ref]$errors)
        Assert-True ($sourceAst.ParamBlock.Extent.Text -ceq $renderAst.ParamBlock.Extent.Text) 'Native parameter block changed.'
        foreach ($comment in @($sourceTokens | Where-Object Kind -eq Comment)) {
            Assert-True ($comment.Text -cin @($renderTokens | Where-Object Kind -eq Comment | ForEach-Object Text)) 'An upstream comment was removed.'
        }
    }
    Test-Case 'Malformed JSON, unsafe paths, ambiguous targets and invalid setting types fail validation' {
        Set-Content $configPath '{broken JSON'
        Assert-Throws { Read-FactoryConfig $configPath } 'Invalid JSON'
        foreach ($path in @('../escape.msi','C:\escape.msi','setup.msi:stream','CON.msi','folder/../setup.msi')) {
            $config = New-TestConfig; $config.install[0].path = $path; Save-TestConfig $config
            Assert-Throws { Read-FactoryConfig $configPath } 'path|component'
        }
        $config = New-TestConfig; $config.install[0] | Add-Member productCode '{12345678-1234-1234-1234-123456789012}'; Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'exactly one'
        $config = New-TestConfig; $config.psadt.closeProcesses = 'false'; Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'JSON boolean'
        $config = New-TestConfig; $config.install[0].arguments = ''; Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'arguments'
        $config = New-TestConfig; $config.psadt.scriptDate = '2026-02-30'; Save-TestConfig $config
        Assert-Throws { Read-FactoryConfig $configPath } 'scriptDate'
    }
    Test-Case 'Empty process and repair lists and user context work without implicit actions' {
        . "$projectRoot/scripts/Update-DeploymentTemplate.ps1"
        $config = New-TestConfig
        $config.psadt.processesToClose = @()
        $config.intune.installContext = 'user'
        Copy-Item "$pristineRoot/Invoke-AppDeployToolkit.ps1" "$detached/Invoke-AppDeployToolkit.ps1" -Force
        Update-FactoryDeploymentTemplate "$detached/Invoke-AppDeployToolkit.ps1" $config
        $state = Invoke-DeploymentProbe $detached @{DeploymentType='Repair'}
        Assert-True ($state.ExitCodes[0] -eq 0 -and $state.Calls.Count -eq 0 -and $state.Welcome.Count -eq 0 -and -not $state.Opened.RequireAdmin) 'Empty repair or user context was not respected.'
    }
    Test-Case 'Generated native command parameters exist in the bundled toolkit version' {
        $tokens=$null; $errors=$null
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile("$pristineRoot/PSAppDeployToolkit/PSAppDeployToolkit.psm1", [ref]$tokens, [ref]$errors)
        $nativeFunctions = @{}
        foreach ($fn in $moduleAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) { $nativeFunctions[$fn.Name] = $fn }
        $entryAst = [Management.Automation.Language.Parser]::ParseFile("$detached/Invoke-AppDeployToolkit.ps1", [ref]$tokens, [ref]$errors)
        foreach ($command in $entryAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]}, $true)) {
            $name = $command.GetCommandName()
            if ($name -and $nativeFunctions.ContainsKey($name)) {
                $parameters = @($nativeFunctions[$name].Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) + @('ErrorAction')
                foreach ($parameter in @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
                    Assert-True ($parameter.ParameterName -in $parameters) "Unsupported native parameter: $name -$($parameter.ParameterName)"
                }
            }
        }
    }
    Test-Case 'Validation alone writes no package and generation has no packaging parameters' {
        $result = & $builder -AppName Fixture -Version 26.05 -Revision 90 -ValidateOnly
        Assert-True ($result.Status -eq 'ConfigurationValid' -and -not (Test-Path "$fixtureRoot/output/Fixture/26.05/rev-90")) 'Validation wrote output.'
        $parameters = (Get-Command $builder).Parameters
        Assert-True (-not $parameters.ContainsKey('CreateIntuneWin') -and -not $parameters.ContainsKey('IntuneWinToolPath')) 'Builder still offers integrated packaging.'
        $metadata = Get-Content "$($built.OutputPath)/build.json" -Raw | ConvertFrom-Json
        Assert-True ($metadata.installCommand -notmatch 'DeployMode' -and $metadata.repairCommand -match 'DeploymentType Repair') 'Build commands hard-code deployment mode or omit repair.'
    }
    Test-Case 'Existing revisions require Force and new revisions preserve inputs and previous output' {
        $before = Get-TreeSnapshot $built.OutputPath
        $inputHash = (Get-FileHash "$fixtureRoot/apps/Fixture/26.05/app.json").Hash
        Assert-Throws { & $builder -AppName Fixture -Version 26.05 } 'Output already exists'
        $next = & $builder -AppName Fixture -Version 26.05 -Revision 02
        Assert-True ((Get-TreeSnapshot $built.OutputPath) -ceq $before) 'New revision changed prior output.'
        Assert-True ((Get-FileHash "$fixtureRoot/apps/Fixture/26.05/app.json").Hash -eq $inputHash) 'Revision override changed source JSON.'
        Assert-True ((Get-Content "$($next.OutputPath)/app.json" -Raw | ConvertFrom-Json).revision -eq '02') 'Revision override missing from snapshot.'
        $null = & $builder -AppName Fixture -Version 26.05 -Force
        Assert-True ((Get-TreeSnapshot $built.OutputPath) -ceq $before) 'Repeated generation changed identical output.'
    }
    Test-Case 'Missing payloads and failed rendering preserve prior output and clean staging' {
        $before = Get-TreeSnapshot $built.OutputPath
        $payload = "$fixtureRoot/apps/Fixture/26.05/installers/repair.exe"
        $bytes = [IO.File]::ReadAllBytes($payload)
        Remove-Item -LiteralPath $payload
        try { Assert-Throws { & $builder -AppName Fixture -Version 26.05 -Force } 'Installer file not found' }
        finally { [IO.File]::WriteAllBytes($payload,$bytes) }
        $template = "$sandbox/sources/PSAppDeployToolkit_Template_v4/Invoke-AppDeployToolkit.ps1"
        $bytes = [IO.File]::ReadAllBytes($template)
        try {
            (Get-Content $template -Raw).Replace('## <Perform Repair tasks here>', '## altered marker') | Set-Content $template -Encoding UTF8
            Assert-Throws { & $builder -AppName Fixture -Version 26.05 -Force } 'Unexpected template structure'
        }
        finally { [IO.File]::WriteAllBytes($template,$bytes) }
        Assert-True ((Get-TreeSnapshot $built.OutputPath) -ceq $before) 'Failed build damaged prior output.'
        Assert-True (@(Get-ChildItem "$fixtureRoot/output/Fixture/26.05" -Force | Where-Object Name -Match '^\.(stage-|backup-|rev-)').Count -eq 0) 'Failed build left staging/lock files.'
    }
    Test-Case 'Failed publish restores the previous package and unrelated output is protected' {
        $before = Get-TreeSnapshot $built.OutputPath
        function Move-Item {
            [CmdletBinding()]param([string]$LiteralPath,[string]$Destination)
            if ((Split-Path $LiteralPath -Leaf) -like '.stage-*') { throw 'Simulated publish failure' }
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
        }
        Assert-Throws { & $builder -AppName Fixture -Version 26.05 -Force } 'Simulated publish failure'
        Assert-True ((Get-TreeSnapshot $built.OutputPath) -ceq $before) 'Publish rollback failed.'
        New-Item -ItemType Directory "$fixtureRoot/output/Fixture/26.05/rev-99" | Out-Null
        Set-Content "$fixtureRoot/output/Fixture/26.05/rev-99/keep.txt" 'Keep'
        Assert-Throws { & $builder -AppName Fixture -Version 26.05 -Revision 99 -Force } 'unrecognized output'
        Assert-True (Test-Path "$fixtureRoot/output/Fixture/26.05/rev-99/keep.txt") 'Unrelated output deleted.'
    }
    Test-Case 'Build locks prevent simultaneous writes to the same revision' {
        $lockPath = "$fixtureRoot/output/Fixture/26.05/.rev-01.lock"
        $lock = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { Assert-Throws { & $builder -AppName Fixture -Version 26.05 -Force } 'Cannot acquire build lock' }
        finally { $lock.Dispose(); Remove-Item -LiteralPath $lockPath }
    }
    if ($WithRealTool) {
        Test-Case 'Separate packaging script packages edited generated content without regeneration' {
            Add-Content "$($built.PackagePath)/Invoke-AppDeployToolkit.ps1" '# Manual review edit retained for packaging'
            $before = Get-TreeSnapshot $built.PackagePath
            $result = & "$projectRoot/scripts/New-IntuneWin.ps1" -SourcePath $built.PackagePath
            Assert-True ($result.Status -eq 'Packaged' -and $result.SizeBytes -gt 0) 'Separate packaging failed.'
            Assert-True ((Get-TreeSnapshot $built.PackagePath) -ceq $before) 'Packaging regenerated or changed reviewed source.'
        }
    }
    Test-Case 'All project scripts parse and original source files remain intact' {
        foreach ($file in @(Get-ChildItem "$projectRoot/scripts/*.ps1") + @(Get-ChildItem "$projectRoot/tests/*.ps1")) {
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            Assert-True (-not $errors) "Syntax error in $($file.Name)"
        }
        Assert-True ((Get-TreeSnapshot $pristineRoot) -ceq (Get-TreeSnapshot "$sandbox/sources/PSAppDeployToolkit_Template_v4")) 'Source template differs from its unchanged test copy.'
    }
}
finally {
    $checked = Get-FactoryPath $sandboxParent (Split-Path $sandbox -Leaf)
    if ($checked -ne $sandbox -or (Split-Path $sandbox -Leaf) -notmatch '^IntuneAppFactory\.Tests-[0-9a-f]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
Write-Host "Tests: $script:passed passed, $script:failed failed. No installers executed."
if ($script:failed) { exit 1 }
