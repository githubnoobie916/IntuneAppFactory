#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$script:passed = 0
$script:failed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        return
    }
    throw "Expected error: $Pattern"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $_" }
}
function New-TestBlobProbe {
    return @{
        Blocks=[Collections.Generic.List[object]]::new(); BlockLists=[Collections.Generic.List[object]]::new()
        Clients=[Collections.Generic.List[string]]::new(); Positions=[Collections.Generic.List[long]]::new()
        FailFirstBlock=$false; Attempts=0; Fetches=0; ReportedLength=[long](4MB + 17)
    }
}
function New-TestBlobClient($Probe, [string]$Uri) {
    $Probe.Clients.Add($Uri)
    $client = [pscustomobject]@{Probe=$Probe;Uri=$Uri;Properties=[pscustomobject]@{Length=0L}}
    $client | Add-Member ScriptMethod PutBlock {
        param($Id, [IO.Stream]$Stream, $Checksum)
        $this.Probe.Attempts++
        $this.Probe.Positions.Add($Stream.Position)
        if ($this.Probe.FailFirstBlock -and $this.Probe.Attempts -eq 1) {
            $null = $Stream.ReadByte()
            if ($this.Probe.LocationToExpire) {
                $this.Probe.LocationToExpire.azureStorageUriExpirationDateTime = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
                throw $this.Probe.ExpiredSasException
            }
            throw 'Simulated transient failure after consuming part of the block.'
        }
        $copy = [IO.MemoryStream]::new()
        try {
            $Stream.CopyTo($copy)
            $this.Probe.Blocks.Add(@{Id=$Id;Bytes=$copy.ToArray();Uri=$this.Uri})
        } finally { $copy.Dispose() }
    }
    $client | Add-Member ScriptMethod PutBlockList {
        param($Ids)
        $this.Probe.BlockLists.Add(@{Ids=@($Ids);Uri=$this.Uri})
    }
    $client | Add-Member ScriptMethod FetchAttributes {
        $this.Probe.Fetches++
        $this.Properties.Length = $this.Probe.ReportedLength
    }
    return $client
}
. "$projectRoot/scripts/IntuneUpload.ps1"
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('IntuneAppFactory.UploadTests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path "$sandbox/IntuneWin" -Force
$config = Get-Content "$projectRoot/apps/7zip/26.05/app.json" -Raw | ConvertFrom-Json
$config | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
$build = [ordered]@{
    factory='IntuneAppFactory'; appName='7zip'; version='26.05'; revision='01'; icon=$null
    installCommand='Invoke-AppDeployToolkit.exe -DeploymentType Install'
    uninstallCommand='Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'; intune=$config.intune
}
$build | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
$archivePath = "$sandbox/IntuneWin/Invoke-AppDeployToolkit.intunewin"
$key = [Convert]::ToBase64String([byte[]]::new(32))
$iv = [Convert]::ToBase64String([byte[]]::new(16))
$xml = "<ApplicationInfo><FileName>IntunePackage.intunewin</FileName><SetupFile>Invoke-AppDeployToolkit.exe</SetupFile><UnencryptedContentSize>12345</UnencryptedContentSize><EncryptionInfo><EncryptionKey>$key</EncryptionKey><MacKey>$key</MacKey><InitializationVector>$iv</InitializationVector><Mac>$key</Mac><ProfileIdentifier>ProfileVersion1</ProfileIdentifier><FileDigest>$key</FileDigest><FileDigestAlgorithm>SHA256</FileDigestAlgorithm></EncryptionInfo></ApplicationInfo>"
$archive = [IO.Compression.ZipFile]::Open($archivePath, 'Create')
try {
    $writer = [IO.StreamWriter]::new($archive.CreateEntry('IntuneWinPackage/Metadata/Detection.xml').Open())
    $writer.Write($xml); $writer.Dispose()
    $stream = $archive.CreateEntry('IntuneWinPackage/Contents/IntunePackage.intunewin').Open()
    $bytes = [byte[]]::new(4MB + 17)
    $bytes[0] = 42; $bytes[-1] = 99
    $stream.Write($bytes, 0, $bytes.Length); $stream.Dispose()
} finally { $archive.Dispose() }
$planArgs = @{ RevisionPath=$sandbox; DeployMode='Silent'; MinimumSupportedWindowsRelease='Windows11_23H2'; RestartBehavior='basedOnReturnCode' }
try {
    Test-Case 'App selection and JSON preview preserve the saved plan and all overrides offline' {
        $factory = Join-Path $sandbox "Factory's files"
        $revision = Join-Path $factory 'apps/7zip/26.05/output/rev-01'
        New-Item -ItemType Directory -Path $revision -Force | Out-Null
        Copy-Item -LiteralPath "$projectRoot/scripts" -Destination $factory -Recurse
        Copy-Item -LiteralPath "$sandbox/app.json","$sandbox/build.json","$sandbox/IntuneWin" -Destination $revision -Recurse
        $uploader = "$factory/scripts/Upload-IntuneWin.ps1"
        $options = @{DeployMode='Silent';MinimumSupportedWindowsRelease='Windows11_23H2';RestartBehavior='basedOnReturnCode';TimeoutSeconds=27;IntuneWinPath=$archivePath;GroupId='11111111-1111-1111-1111-111111111111';AssignmentIntent='available'}
        $app = @{AppName='7zip';Version='26.05';Revision='01'}
        function Connect-MgGraph { throw 'Unexpected authentication' }
        function Invoke-MgGraphRequest { throw 'Unexpected network operation' }
        Push-Location $sandbox
        try {
            $byPath = & $uploader -RevisionPath $revision @options -Preview
            $byApp = & $uploader @app @options -Preview
            Assert-True ($byApp -is [pscustomobject]) 'Plain preview must return an object.'
            Assert-True (($byApp | ConvertTo-Json -Depth 20) -ceq ($byPath | ConvertTo-Json -Depth 20)) 'Selection changed the upload plan.'
            $json = & $uploader @app @options -Preview -AsJson
            Assert-True ($json -is [string]) 'JSON preview must return a single string.'
            $parsed = $json | ConvertFrom-Json
            Assert-True (($parsed | ConvertTo-Json -Depth 20) -ceq ($byPath | ConvertTo-Json -Depth 20)) 'JSON preview lost plan fields.'
            $whatif = & $uploader @app @options -WhatIf
            Assert-True ($whatif.SHA256 -eq $byPath.SHA256) 'WhatIf changed the plan.'
            $alias = & $uploader -AppName 7zip -AppVersion 26.05 -Revision '01' @options -Preview
            Assert-True ($alias.RevisionPath -eq $byPath.RevisionPath) 'AppVersion alias failed.'
            $defaultArchive = & $uploader @app -DeployMode Silent -MinimumSupportedWindowsRelease Windows11_23H2 -RestartBehavior basedOnReturnCode -Preview
            Assert-True ($defaultArchive.IntuneWinPath -eq (Join-Path $revision 'IntuneWin/Invoke-AppDeployToolkit.intunewin')) 'Default archive not selected.'
            # There is no source app.json in this copied factory: only the saved revision is used.
            Assert-Throws { & $uploader @app -RevisionPath $revision -Preview } 'parameter set'
            Assert-Throws { & $uploader -RevisionPath "$sandbox/missing" -AsJson } 'AsJson.*Preview'
            Assert-Throws { & $uploader @app -AsJson -WhatIf } 'AsJson.*Preview'
            $sets = (Get-Command $uploader).ParameterSets
            $appSet = @($sets | Where-Object { 'AppName' -in $_.Parameters.Name })
            foreach ($name in @('AppName','Version','Revision')) {
                Assert-True (@($appSet[0].Parameters | Where-Object { $_.Name -eq $name -and $_.IsMandatory }).Count -eq 1) "$name must be mandatory."
            }
            $changed = Get-Content "$revision/build.json" -Raw | ConvertFrom-Json
            $changed.appName = 'wrong'
            $changed | ConvertTo-Json -Depth 20 | Set-Content "$revision/build.json"
            Assert-Throws { & $uploader @app @options -Preview } 'metadata|match'
        } finally { Pop-Location }
    }
    Test-Case 'Old output remains previewable by explicit revision path without app-name fallback' {
        $oldFactory = Join-Path $sandbox 'Old factory'
        $oldRevision = Join-Path $oldFactory 'output/7zip/26.05/rev-01'
        New-Item -ItemType Directory -Path $oldRevision -Force | Out-Null
        Copy-Item -LiteralPath "$projectRoot/scripts" -Destination $oldFactory -Recurse
        Copy-Item -LiteralPath "$sandbox/app.json","$sandbox/build.json","$sandbox/IntuneWin" -Destination $oldRevision -Recurse
        $oldUploader = "$oldFactory/scripts/Upload-IntuneWin.ps1"
        $options = @{DeployMode='Silent';MinimumSupportedWindowsRelease='Windows11_23H2';RestartBehavior='basedOnReturnCode';Preview=$true}
        $plan = & $oldUploader -RevisionPath $oldRevision @options
        Assert-True ($plan.IntuneWinPath -eq (Join-Path $oldRevision 'IntuneWin/Invoke-AppDeployToolkit.intunewin')) 'Explicit old-path upload preview failed.'
        Assert-Throws { & $oldUploader -AppName 7zip -Version 26.05 -Revision '01' @options } 'Revision directory not found'
    }
    Test-Case 'PowerShell detection preserves bytes, uses the revision snapshot and rejects changed content' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        $originalBuild = Get-Content "$sandbox/build.json" -Raw
        try {
            $configured = $originalConfig | ConvertFrom-Json
            $configured.intune.detection = [pscustomobject]@{type='powershell';scriptPath='detection/source.ps1';runAs32Bit=$false;enforceSignatureCheck=$true}
            $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
            $null = New-Item -ItemType Directory "$sandbox/Detection" -Force
            $scriptBytes = [byte[]](@(239,187,191) + [Text.Encoding]::UTF8.GetBytes('throw "Must never execute during build or preview"'))
            [IO.File]::WriteAllBytes("$sandbox/Detection/Detect.ps1", $scriptBytes)
            $updatedBuild = $originalBuild | ConvertFrom-Json
            $updatedBuild.intune = $configured.intune
            $updatedBuild | Add-Member detectionScript ([pscustomobject]@{path='Detection/Detect.ps1';sha256=(Get-FileHash "$sandbox/Detection/Detect.ps1").Hash})
            $updatedBuild | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
            $plan = Get-FactoryUploadPlan @planArgs
            $rule = $plan.AppBody.rules[0]
            Assert-True ($rule.'@odata.type' -eq '#microsoft.graph.win32LobAppPowerShellScriptRule' -and $rule.ruleType -eq 'detection') 'Incorrect Graph rule.'
            Assert-True ($rule.scriptContent -ceq [Convert]::ToBase64String($scriptBytes)) 'Script encoding changed, including BOM.'
            Assert-True ($rule.enforceSignatureCheck -and -not $rule.runAs32Bit) 'Script settings changed.'
            Assert-True ($rule.operationType -eq 'notConfigured' -and $rule.operator -eq 'notConfigured') 'Detection compared output.'
            Assert-True (-not $rule.ContainsKey('runAsAccount') -and -not $rule.ContainsKey('displayName') -and -not $rule.ContainsKey('comparisonValue')) 'Requirement-only fields emitted.'
            Set-Content "$sandbox/Detection/Detect.ps1" 'exit 1'
            Assert-Throws { Get-FactoryUploadPlan @planArgs } 'hash|changed'
            Remove-Item "$sandbox/Detection/Detect.ps1"
            Assert-Throws { Get-FactoryUploadPlan @planArgs } 'not found'
        } finally {
            Set-Content "$sandbox/app.json" $originalConfig
            Set-Content "$sandbox/build.json" $originalBuild
        }
    }
    Test-Case 'PowerShell detection schema rejects unsafe paths and non-boolean flags' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        try {
            foreach ($mutate in @(
                { param($d) $d.scriptPath = '../outside.ps1' },
                { param($d) $d.scriptPath = 'script.exe' },
                { param($d) $d.runAs32Bit = 'false' },
                { param($d) $d.enforceSignatureCheck = 0 },
                { param($d) $d.type = @('powershell') },
                { param($d) $d | Add-Member runAsAccount 'system' }
            )) {
                $configured = $originalConfig | ConvertFrom-Json
                $configured.intune.detection = [pscustomobject]@{type='powershell';scriptPath='detection/Detect.ps1';runAs32Bit=$false;enforceSignatureCheck=$false}
                & $mutate $configured.intune.detection
                $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
                Assert-Throws { Read-FactoryConfig -Path "$sandbox/app.json" -ExpectedVersion '26.05' } '.'
            }
        } finally { Set-Content "$sandbox/app.json" $originalConfig }
    }
    Test-Case 'JSON alone configures publication, registry version detection and transport' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        $originalBuild = Get-Content "$sandbox/build.json" -Raw
        try {
            $configured = $originalConfig | ConvertFrom-Json
            $configured.intune | Add-Member informationUrl 'https://example.com/app'
            $configured.intune | Add-Member upload ([pscustomobject]@{
                deployMode='NonInteractive'; minimumSupportedWindowsRelease='Windows11_24H2'; restartBehavior='suppress'
                returnCodes=@([pscustomobject]@{returnCode=0;type='success'},[pscustomobject]@{returnCode=42;type='retry'})
                transport=[pscustomobject]@{maxRetries=0;blockSizeBytes=1048576;sasRenewalThresholdMinutes=5;timeoutSeconds=120}
            })
            $configured.intune.detection = [pscustomobject]@{type='registry';key='HKEY_LOCAL_MACHINE\SOFTWARE\Test';valueName='DisplayVersion';value='8.9.7.0';operationType='version';operator='greaterThanOrEqual';check32BitOn64System=$true}
            $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
            $updatedBuild = $originalBuild | ConvertFrom-Json
            $updatedBuild.intune = $configured.intune
            $updatedBuild | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
            $plan = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -Preview
            Assert-True ($plan.AppBody.installCommandLine -match '-DeployMode NonInteractive$') 'JSON deployment mode ignored.'
            Assert-True ($plan.AppBody.informationUrl -eq 'https://example.com/app') 'Information URL ignored.'
            Assert-True ($plan.AppBody.installExperience.deviceRestartBehavior -eq 'suppress') 'Restart choice ignored.'
            Assert-True ($plan.AppBody.rules[0].operationType -eq 'version' -and $plan.AppBody.rules[0].check32BitOn64System) 'Registry version or view ignored.'
            Assert-True ($plan.AppBody.returnCodes.Count -eq 2 -and $plan.AppBody.returnCodes[1].returnCode -eq 42) 'Custom return codes changed.'
            Assert-True ($plan.Transport.MaxRetries -eq 0 -and $plan.Transport.BlockSizeBytes -eq 1MB -and $plan.Transport.TimeoutSeconds -eq 120) 'Transport choices ignored.'
            $override = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -DeployMode Silent -RestartBehavior allow -MinimumSupportedWindowsRelease Windows11_25H2 -TimeoutSeconds 15 -Preview
            Assert-True ($override.AppBody.installCommandLine -match '-DeployMode Silent$' -and $override.AppBody.installExperience.deviceRestartBehavior -eq 'allow' -and $override.Transport.TimeoutSeconds -eq 15 -and $override.AppBody.minimumSupportedWindowsRelease -eq 'Windows11_25H2') 'CLI precedence failed.'
        } finally {
            Set-Content "$sandbox/app.json" $originalConfig
            Set-Content "$sandbox/build.json" $originalBuild
        }
    }
    Test-Case 'Missing upload settings fail locally without prompting' {
        Assert-Throws { Get-FactoryUploadPlan -RevisionPath $sandbox } 'MinimumSupportedWindowsRelease.*required'
    }
    Test-Case 'Windows 10 and Windows 11 minimum releases work in JSON and CLI previews' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        $originalBuild = Get-Content "$sandbox/build.json" -Raw
        try {
            foreach ($release in @('1809','22H2','Windows11_24H2')) {
                $configured = $originalConfig | ConvertFrom-Json
                $configured.intune | Add-Member upload ([pscustomobject]@{deployMode='Silent';minimumSupportedWindowsRelease=$release;restartBehavior='allow'})
                $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
                $updatedBuild = $originalBuild | ConvertFrom-Json
                $updatedBuild.intune = $configured.intune
                $updatedBuild | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
                $jsonPlan = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -Preview
                Assert-True ($jsonPlan.AppBody.minimumSupportedWindowsRelease -ceq $release) "JSON release '$release' changed."
                $cliPlan = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -MinimumSupportedWindowsRelease $release -Preview
                Assert-True ($cliPlan.AppBody.minimumSupportedWindowsRelease -ceq $release) "CLI release '$release' changed."
            }
        } finally {
            Set-Content "$sandbox/app.json" $originalConfig
            Set-Content "$sandbox/build.json" $originalBuild
        }
    }
    Test-Case 'Unreleased Windows version is rejected by JSON and CLI before authentication' {
        $upload = [pscustomobject]@{deployMode='Silent';minimumSupportedWindowsRelease='Windows11_24H1';restartBehavior='allow'}
        Assert-Throws { Assert-FactoryUploadConfig $upload } 'release|Windows'
        function Connect-MgGraph { throw 'Unexpected authentication' }
        Assert-Throws { & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -DeployMode Silent -MinimumSupportedWindowsRelease Windows11_24H1 -RestartBehavior allow -Preview } 'release|Windows'
        Assert-Throws { Get-FactoryUploadPlan -RevisionPath $sandbox -DeployMode Silent -MinimumSupportedWindowsRelease Windows11_24H1 -RestartBehavior allow } 'release|Windows'
    }
    Test-Case 'Auto is the default and deployment mode follows CLI then JSON precedence' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        $originalBuild = Get-Content "$sandbox/build.json" -Raw
        try {
            $configured = $originalConfig | ConvertFrom-Json
            $configured.intune | Add-Member upload ([pscustomobject]@{minimumSupportedWindowsRelease='22H2';restartBehavior='allow'})
            foreach ($mode in @($null,'Silent','Auto')) {
                if ($null -ne $mode) { $configured.intune.upload | Add-Member deployMode $mode -Force }
                $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
                $updatedBuild = $originalBuild | ConvertFrom-Json
                $updatedBuild.intune = $configured.intune
                $updatedBuild | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
                $expected = if ($null -eq $mode) { 'Auto' } else { $mode }
                $plan = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -Preview
                Assert-True ($plan.AppBody.installCommandLine -match "-DeployMode $expected`$") "Install did not resolve mode '$expected'."
                Assert-True ($plan.AppBody.uninstallCommandLine -match "-DeployMode $expected`$") "Uninstall did not resolve mode '$expected'."
                $override = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -DeployMode Interactive -Preview
                Assert-True ($override.AppBody.installCommandLine -match '-DeployMode Interactive$') 'Explicit CLI mode did not override JSON/default.'
                $auto = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -DeployMode Auto -Preview
                Assert-True ($auto.AppBody.installCommandLine -match '-DeployMode Auto$') 'CLI Auto is not accepted.'
            }
        } finally {
            Set-Content "$sandbox/app.json" $originalConfig
            Set-Content "$sandbox/build.json" $originalBuild
        }
    }
    Test-Case 'Optional metadata defaults omit requirements and publish the root display version' {
        $plan = Get-FactoryUploadPlan @planArgs
        Assert-True ($plan.ApiVersion -eq 'beta') 'Preview does not identify the beta API.'
        Assert-True ($plan.AppBody.displayVersion -eq '26.05') 'Display version did not default from root version.'
        Assert-True (@($plan.CategoryIds).Count -eq 0) 'Unexpected default categories.'
        foreach ($field in @('developer','owner','privacyInformationUrl','isFeatured','allowAvailableUninstall','roleScopeTagIds','minimumFreeDiskSpaceInMB','minimumMemoryInMB','minimumNumberOfProcessors','minimumCpuSpeedInMHz')) {
            Assert-True (-not $plan.AppBody.ContainsKey($field)) "Unspecified '$field' was sent to Graph."
        }
        Assert-True (-not $plan.AppBody.installExperience.ContainsKey('maxRunTimeInMinutes')) 'Unspecified installation runtime was sent to Graph.'
    }
    Test-Case 'JSON metadata maps to beta app properties and separates category relationships' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        $originalBuild = Get-Content "$sandbox/build.json" -Raw
        try {
            $configured = $originalConfig | ConvertFrom-Json
            $metadata = @{
                displayVersion='26.05-company';developer='Example developer';owner='Endpoint team'
                privacyInformationUrl='https://example.com/privacy';notes='Approved package';isFeatured=$false
                allowAvailableUninstall=$true;categoryIds=@('12345678-1234-1234-1234-123456789abc');roleScopeTagIds=@('0','12')
            }
            foreach ($name in $metadata.Keys) { $configured.intune | Add-Member $name $metadata[$name] }
            $configured.intune | Add-Member upload ([pscustomobject]@{
                minimumSupportedWindowsRelease='22H2';restartBehavior='allow';maxRunTimeInMinutes=15
                minimumFreeDiskSpaceInMB=500;minimumMemoryInMB=0;minimumNumberOfProcessors=2;minimumCpuSpeedInMHz=1200
            })
            foreach ($boolean in @($true,$false)) {
                $configured.intune.allowAvailableUninstall = $boolean
                $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
                $updatedBuild = $originalBuild | ConvertFrom-Json
                $updatedBuild.intune = $configured.intune
                $updatedBuild | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
                $plan = & "$projectRoot/scripts/Upload-IntuneWin.ps1" -RevisionPath $sandbox -Preview
                foreach ($name in @('displayVersion','developer','owner','privacyInformationUrl','notes','isFeatured')) {
                    Assert-True ($plan.AppBody.ContainsKey($name) -and $plan.AppBody[$name] -ceq $metadata[$name]) "Metadata '$name' changed or omitted."
                }
                Assert-True ($plan.AppBody.ContainsKey('allowAvailableUninstall') -and $plan.AppBody.allowAvailableUninstall -eq $boolean) 'Explicit uninstall boolean was lost.'
                Assert-True ($plan.AppBody.roleScopeTagIds.Count -eq 2 -and $plan.AppBody.roleScopeTagIds[0] -is [string] -and $plan.AppBody.roleScopeTagIds[1] -ceq '12') 'Scope tag IDs changed.'
                Assert-True ($plan.CategoryIds.Count -eq 1 -and $plan.CategoryIds[0] -ceq $metadata.categoryIds[0]) 'Category relationship IDs missing.'
                Assert-True (-not $plan.AppBody.ContainsKey('categoryIds') -and -not $plan.AppBody.ContainsKey('categories')) 'Categories were embedded in the app create body.'
                Assert-True ($plan.AppBody.installExperience.maxRunTimeInMinutes -eq 15 -and $plan.Transport.TimeoutSeconds -eq 900) 'Installation runtime was confused with upload timeout.'
                foreach ($name in @('minimumFreeDiskSpaceInMB','minimumMemoryInMB','minimumNumberOfProcessors','minimumCpuSpeedInMHz')) {
                    Assert-True ($plan.AppBody.ContainsKey($name) -and $plan.AppBody[$name] -eq $configured.intune.upload.$name) "Requirement '$name' changed or omitted."
                }
            }
            $configured.intune.categoryIds = @(); $configured.intune.roleScopeTagIds = @()
            $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
            $updatedBuild.intune = $configured.intune
            $updatedBuild | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/build.json"
            $emptyPlan = Get-FactoryUploadPlan -RevisionPath $sandbox
            Assert-True ($emptyPlan.CategoryIds.Count -eq 0 -and $emptyPlan.AppBody.ContainsKey('roleScopeTagIds') -and $emptyPlan.AppBody.roleScopeTagIds.Count -eq 0) 'Explicit empty collections were lost.'
        } finally {
            Set-Content "$sandbox/app.json" $originalConfig
            Set-Content "$sandbox/build.json" $originalBuild
        }
    }
    Test-Case 'Metadata types and tenant identifiers are validated locally' {
        $originalConfig = Get-Content "$sandbox/app.json" -Raw
        try {
            foreach ($case in @(
                @{Name='isFeatured';Value='false'}, @{Name='allowAvailableUninstall';Value=1},
                @{Name='categoryIds';Value=@('not-a-guid')}, @{Name='categoryIds';Value='12345678-1234-1234-1234-123456789abc'},
                @{Name='roleScopeTagIds';Value=@(12)}, @{Name='roleScopeTagIds';Value=@('tag-name')},
                @{Name='displayVersion';Value=@('1.0')}, @{Name='owner';Value=42},
                @{Name='privacyInformationUrl';Value='not-a-url'}
            )) {
                $configured = $originalConfig | ConvertFrom-Json
                $configured.intune | Add-Member $case.Name $case.Value
                $configured | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
                Assert-Throws { Read-FactoryConfig -Path "$sandbox/app.json" -ExpectedVersion '26.05' } $case.Name
            }
        } finally { Set-Content "$sandbox/app.json" $originalConfig }
    }
    Test-Case 'Runtime and hardware requirements accept boundaries and reject invalid values' {
        foreach ($field in @('maxRunTimeInMinutes','minimumFreeDiskSpaceInMB','minimumMemoryInMB','minimumNumberOfProcessors','minimumCpuSpeedInMHz')) {
            $minimum = if ($field -eq 'maxRunTimeInMinutes') { 1 } else { 0 }
            $maximum = if ($field -eq 'maxRunTimeInMinutes') { 1440 } else { [int]::MaxValue }
            foreach ($value in @($minimum,$maximum)) {
                $upload = [pscustomobject]@{minimumSupportedWindowsRelease='22H2';restartBehavior='allow'}
                $upload | Add-Member $field $value
                Assert-FactoryUploadConfig $upload
            }
            foreach ($value in @(($minimum - 1),([long]$maximum + 1),1.5,'15',$null)) {
                $upload = [pscustomobject]@{minimumSupportedWindowsRelease='22H2';restartBehavior='allow'}
                $upload | Add-Member $field $value
                Assert-Throws { Assert-FactoryUploadConfig $upload } $field
            }
        }
    }
    Test-Case 'JSON enum fields reject singleton arrays before Graph publication' {
        foreach ($field in @('deployMode','restartBehavior','returnCodeType','operationType','operator')) {
            $example = Get-Content "$projectRoot/examples/notepadplusplus/8.9.7/app.json" -Raw | ConvertFrom-Json
            switch ($field) {
                'deployMode' { $example.intune.upload.deployMode = @('Silent') }
                'restartBehavior' { $example.intune.upload.restartBehavior = @('suppress') }
                'returnCodeType' { $example.intune.upload.returnCodes[0].type = @('success') }
                'operationType' { $example.intune.detection.operationType = @('version') }
                'operator' { $example.intune.detection.operator = @('greaterThanOrEqual') }
            }
            if ($field -in @('operationType','operator')) {
                Assert-Throws { Assert-FactoryRegistryDetectionOptions $example.intune.detection } 'string'
            } else {
                Assert-Throws { Assert-FactoryUploadConfig $example.intune.upload } 'string'
            }
        }
    }
    Test-Case 'Preview uses revision metadata and exposes no encryption secrets' {
        $plan = Get-FactoryUploadPlan @planArgs
        Assert-True ($plan.AppBody.installCommandLine -eq 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent') 'Wrong install command.'
        Assert-True ($plan.AppBody.rules[0].operationType -eq 'version') 'Missing version detection.'
        Assert-True ($plan.AppBody.rules[0].operator -eq 'greaterThanOrEqual') 'Wrong detection comparison.'
        Assert-True ($plan.FileBody.size -eq 12345 -and $plan.FileBody.sizeEncrypted -eq (4MB + 17)) 'Wrong inner content sizes.'
        Assert-True (($plan | ConvertTo-Json -Depth 20) -notmatch 'encryptionKey|macKey|azureStorageUri') 'Secret in preview.'
    }
    Test-Case 'Null detection is rejected before contacting Intune' {
        $invalid = Get-Content "$projectRoot/apps/7zip/26.05/app.json" -Raw | ConvertFrom-Json
        $invalid.intune.detection = $null
        $invalid | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
        Assert-Throws { Get-FactoryUploadPlan @planArgs } 'detection'
        $config = Get-Content "$projectRoot/apps/7zip/26.05/app.json" -Raw | ConvertFrom-Json
        $config | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
    }
    Test-Case 'MSI and registry rules preserve configured meaning' {
        $msi = ConvertTo-FactoryDetectionRule ([pscustomobject]@{type='msi';productCode='{12345678-1234-1234-1234-123456789ABC}'}) 'x64'
        Assert-True ($msi.productVersionOperator -eq 'notConfigured') 'Invented MSI version.'
        $reg = ConvertTo-FactoryDetectionRule ([pscustomobject]@{type='registry';key='HKEY_LOCAL_MACHINE\Software\Test';valueName='';value=''}) 'x86'
        Assert-True ($reg.operationType -eq 'string' -and $reg.comparisonValue -eq '' -and $reg.check32BitOn64System) 'Registry equality or view changed.'
    }
    Test-Case 'Upload streams the encrypted inner payload including the final partial block' {
        $probe = New-TestBlobProbe
        function New-FactoryBlobClient($Uri) { New-TestBlobClient $probe $Uri }
        $location = @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=redacted';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/deviceAppManagement/mobileApps/test/files/test' -Location $location -TimeoutSeconds 10
        Assert-True ($probe.Blocks.Count -eq 2 -and $probe.BlockLists.Count -eq 1) 'Expected two data blocks and one committed block list.'
        Assert-True ($probe.Blocks[0].Bytes.Length -eq 4MB -and $probe.Blocks[0].Bytes[0] -eq 42) 'Wrong first block.'
        Assert-True ($probe.Blocks[1].Bytes.Length -eq 17 -and $probe.Blocks[1].Bytes[-1] -eq 99) 'Final block was corrupted.'
        Assert-True (($probe.BlockLists[0].Ids -join ',') -ceq ($probe.Blocks.Id -join ',')) 'Committed block list does not preserve upload order.'
        Assert-True ($probe.Fetches -eq 1) 'Uploaded blob size was not verified.'
        $probe = New-TestBlobProbe
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/test' -Location $location -TimeoutSeconds 10 -BlockSizeBytes 1MB -MaxRetries 0 -SasRenewalThresholdMinutes 5
        Assert-True ($probe.Blocks.Count -eq 5 -and $probe.Blocks[0].Bytes.Length -eq 1MB -and $probe.Blocks[4].Bytes.Length -eq 17) 'Configured block size not used.'
    }
    Test-Case 'Blob retries reset a partially consumed stream before resending' {
        $probe = New-TestBlobProbe
        $probe.FailFirstBlock = $true
        function New-FactoryBlobClient($Uri) { New-TestBlobClient $probe $Uri }
        function Start-Sleep { }
        $location = @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=redacted';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/test' -Location $location -MaxRetries 1
        Assert-True ($probe.Attempts -eq 3 -and $probe.Positions[0] -eq 0 -and $probe.Positions[1] -eq 0) 'Retry did not rewind the failed block.'
        Assert-True ($probe.Blocks[0].Bytes.Length -eq 4MB -and $probe.Blocks[0].Bytes[0] -eq 42 -and $probe.Blocks[1].Bytes[-1] -eq 99) 'Retry corrupted encrypted payload.'
    }
    Test-Case 'A committed blob with the wrong size is rejected' {
        $probe = New-TestBlobProbe
        $probe.ReportedLength = 1L
        function New-FactoryBlobClient($Uri) { New-TestBlobClient $probe $Uri }
        $location = @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=redacted';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        Assert-Throws { Send-FactoryEncryptedContent -Path $archivePath -FileUri '/test' -Location $location -MaxRetries 0 } 'size|length'
        Assert-True ($probe.BlockLists.Count -eq 1 -and $probe.Fetches -eq 1) 'Blob size was not checked after committing blocks.'
    }
    Test-Case 'A SAS that expires during a block attempt is renewed before replaying the full block' {
        Add-Type -TypeDefinition @'
public class FactoryTestStorageResponse { public int HttpStatusCode { get; set; } = 403; }
public class FactoryTestExpiredSasException : System.Exception {
    public FactoryTestStorageResponse RequestInformation { get; } = new FactoryTestStorageResponse();
}
'@
        $location = @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=old';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        $probe = New-TestBlobProbe
        $probe.FailFirstBlock = $true
        $probe.LocationToExpire = $location
        $probe.ExpiredSasException = [FactoryTestExpiredSasException]::new()
        $renewalProbe = @{Renewals=0}
        function New-FactoryBlobClient($Uri) { New-TestBlobClient $probe $Uri }
        function Start-Sleep { }
        function Invoke-FactoryGraph($Method='GET', $Uri, $Body) {
            if ($Method -eq 'POST' -and $Uri -eq '/test/renewUpload') { $renewalProbe.Renewals++; return }
            if ($Method -eq 'GET' -and $Uri -eq '/test') {
                return @{uploadState='azureStorageUriRenewalSuccess';azureStorageUri='https://test.blob.core.windows.net/c/b?sig=renewed';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
            }
            throw "Unexpected renewal operation: $Method $Uri"
        }
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/test' -Location $location -MaxRetries 1
        Assert-True ($renewalProbe.Renewals -eq 1) 'An expired SAS was not renewed exactly once during the retry.'
        Assert-True ($probe.Clients[0] -match 'sig=old$' -and $probe.Clients[1] -match 'sig=renewed$') 'Retry did not rebuild the client with the renewed SAS.'
        Assert-True ($probe.Attempts -eq 3 -and $probe.Positions[0] -eq 0 -and $probe.Positions[1] -eq 0) 'Retry did not rewind the partially consumed block.'
        Assert-True ($probe.Blocks[0].Bytes.Length -eq 4MB -and $probe.Blocks[0].Bytes[0] -eq 42 -and $probe.Blocks[0].Uri -match 'sig=renewed$' -and $probe.Blocks[1].Bytes[-1] -eq 99) 'Renewal replay changed the encrypted payload.'
        Assert-True ($probe.BlockLists.Count -eq 1 -and $probe.Fetches -eq 1) 'Renewed upload did not complete size verification.'
    }
    Test-Case 'Renewed storage credentials rebuild the Blob client for subsequent operations' {
        $probe = New-TestBlobProbe
        $renewalProbe = @{Calls=0}
        function New-FactoryBlobClient($Uri) { New-TestBlobClient $probe $Uri }
        function Update-FactoryUploadLocation($FileUri, $Location, $TimeoutSeconds, $SasRenewalThresholdMinutes) {
            $renewalProbe.Calls++
            if ($renewalProbe.Calls -gt 1) { return @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=renewed';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')} }
            return $Location
        }
        $location = @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=old';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/test' -Location $location -MaxRetries 0
        Assert-True ($probe.Blocks[0].Uri -match 'sig=old$' -and $probe.Blocks[-1].Uri -match 'sig=renewed$') 'Blocks continued using stale SAS credentials.'
        Assert-True ($probe.BlockLists[0].Uri -match 'sig=renewed$') 'Block-list commit used stale SAS credentials.'
    }
    Test-Case 'Failed service states stop immediately and never count as success' {
        function Invoke-FactoryGraph { @{ uploadState='commitFileFailed' } }
        Assert-Throws { Wait-FactoryUploadState -Uri '/test' -ExpectedState 'commitFileSuccess' -TimeoutSeconds 1 } 'commitFileFailed'
    }
    Test-Case 'Pending service states have a bounded timeout' {
        function Invoke-FactoryGraph { @{ uploadState='commitFilePending' } }
        Assert-Throws { Wait-FactoryUploadState -Uri '/test' -ExpectedState 'commitFileSuccess' -TimeoutSeconds 1 -PollSeconds 1 } 'Timed out'
    }
    Test-Case 'Storage URLs cannot redirect uploads outside Azure HTTPS endpoints' {
        foreach ($uri in @('http://test.blob.core.windows.net/a?sig=x','https://evil.example/a?sig=x','https://test.blob.core.windows.net.evil.example/a?sig=x')) {
            Assert-Throws { Assert-FactoryStorageUri $uri } 'Azure Blob'
        }
    }
    Test-Case 'Publication commits the file before the app and records a verified result' {
        $script:calls = [Collections.Generic.List[object]]::new()
        $script:commitFails = $false
        function Invoke-FactoryGraph($Method='GET', $Uri, $Body) {
            $script:calls.Add(@{Method=$Method;Uri=$Uri;Body=$Body})
            if ($Uri.Contains('?')) { return @{value=@()} }
            if ($Method -eq 'POST' -and $Uri -eq '/deviceAppManagement/mobileApps') { return @{id='app-id'} }
            if ($Uri -match '/contentVersions$') { return @{id='1'} }
            if ($Uri -match '/files$') { return @{id='file-id'} }
            if ($Uri -match '/files/file-id$') {
                if (@($script:calls | Where-Object Uri -match '/commit$').Count) {
                    if ($script:commitFails) { return @{uploadState='commitFileFailed';isCommitted=$false} }
                    return @{uploadState='commitFileSuccess';isCommitted=$true}
                }
                return @{uploadState='azureStorageUriRequestSuccess';azureStorageUri='https://test.blob.core.windows.net/a?sig=fake'}
            }
            if ($Uri -match '/assignments$') { return @{id='assignment-id'} }
            if ($Method -eq 'GET' -and $Uri -eq '/deviceAppManagement/mobileApps/app-id') { return @{publishingState='published';committedContentVersion='1'} }
        }
        function Send-FactoryEncryptedContent { }
        $plan = Get-FactoryUploadPlan @planArgs
        $result = Invoke-FactoryPublishPlan -Plan $plan -TenantId '11111111-1111-1111-1111-111111111111' -TimeoutSeconds 1
        Assert-True ($result.Status -eq 'Published' -and $result.AppId -eq 'app-id') 'Publication result incorrect.'
        $receipt = Get-Content -LiteralPath $result.ReceiptPath -Raw | ConvertFrom-Json
        Assert-True ($receipt.Status -eq 'Published' -and $receipt.SHA256 -eq $plan.SHA256) 'Receipt is not bound to package.'
        $patch = @($script:calls | Where-Object Method -eq 'PATCH')
        Assert-True ($patch.Count -eq 1 -and $patch[0].Body.committedContentVersion -eq '1') 'Content version not committed.'
        Assert-True (@($script:calls | Where-Object Uri -match '/assignments$').Count -eq 0) 'Unexpected assignment.'
        Assert-Throws { Invoke-FactoryPublishPlan -Plan $plan -TenantId '11111111-1111-1111-1111-111111111111' } 'receipt already exists'

        $script:calls.Clear()
        $plan.Assignments = @(@{intent='available';target=@{groupId='55555555-5555-5555-5555-555555555555'}})
        $assigned = Invoke-FactoryPublishPlan -Plan $plan -TenantId '55555555-5555-5555-5555-555555555555' -TimeoutSeconds 1
        Assert-True ($assigned.Assignments.Count -eq 1 -and $assigned.Assignments[0].Id -eq 'assignment-id') 'Assignment result missing.'
        $lastCalls = @($script:calls | Select-Object -Last 2)
        Assert-True ($lastCalls[0].Method -eq 'GET' -and $lastCalls[1].Uri -match '/assignments$') 'Assignment preceded publication verification.'

        $script:calls.Clear(); $script:commitFails = $true
        Assert-Throws { Invoke-FactoryPublishPlan -Plan $plan -TenantId '66666666-6666-6666-6666-666666666666' -TimeoutSeconds 1 } 'commitFileFailed'
        Assert-True (@($script:calls | Where-Object { $_.Method -eq 'PATCH' -or $_.Uri -match '/assignments$' }).Count -eq 0) 'Failed content was published or assigned.'
        $failedReceipt = Get-Content "$sandbox/upload-66666666-6666-6666-6666-666666666666.json" -Raw | ConvertFrom-Json
        Assert-True ($failedReceipt.AppId -eq 'app-id' -and $failedReceipt.Status -eq 'Failed') 'Failed upload lost recovery state.'

        $script:calls.Clear(); $script:commitFails = $false
        function Send-FactoryEncryptedContent { throw 'Uploaded blob size does not match encrypted payload.' }
        Assert-Throws { Invoke-FactoryPublishPlan -Plan $plan -TenantId '77777777-7777-7777-7777-777777777777' -TimeoutSeconds 1 } 'size does not match'
        Assert-True (@($script:calls | Where-Object { $_.Method -eq 'PATCH' -or $_.Uri -match '/commit$|/assignments$' }).Count -eq 0) 'A size mismatch was committed, published or assigned.'
    }
    Test-Case 'Preview and WhatIf run without an authentication module or network' {
        function Connect-MgGraph { throw 'Unexpected authentication' }
        function Invoke-MgGraphRequest { throw 'Unexpected network' }
        $preview = & "$projectRoot/scripts/Upload-IntuneWin.ps1" @planArgs -Preview
        Assert-True ($preview.SHA256 -match '^[0-9A-F]{64}$') 'Preview did not return a plan.'
        $whatif = & "$projectRoot/scripts/Upload-IntuneWin.ps1" @planArgs -WhatIf
        Assert-True ($whatif.SHA256 -eq $preview.SHA256) 'WhatIf did not return the local plan.'
    }
    Test-Case 'Default delegated authentication omits ClientId and checks tenant before writes' {
        function Get-Module { return @{Name='Microsoft.Graph.Authentication'} }
        function Import-Module { }
        function Connect-MgGraph {
            [CmdletBinding()]param($TenantId,$Environment,$ContextScope,[switch]$NoWelcome,$Scopes,$ClientId)
            $authProbe.Connected = $PSBoundParameters
        }
        function Get-MgContext { return @{TenantId='wrong-tenant';Environment='Global'} }
        function Disconnect-MgGraph { $authProbe.Disconnected = $true }
        $authProbe = @{Connected=$null;Disconnected=$false}
        Assert-Throws { & "$projectRoot/scripts/Upload-IntuneWin.ps1" @planArgs -TenantId '22222222-2222-2222-2222-222222222222' } 'session does not match'
        Assert-True ($authProbe.Connected -and -not $authProbe.Connected.ContainsKey('ClientId')) 'Default authentication passed an invalid client ID.'
        Assert-True ($authProbe.Disconnected) 'Owned connection not disconnected after failure.'
    }
    Test-Case 'Missing tenant and certificate client IDs fail with actionable errors' {
        Assert-Throws { & "$projectRoot/scripts/Upload-IntuneWin.ps1" @planArgs } 'TenantId is required'
        Assert-Throws { & "$projectRoot/scripts/Upload-IntuneWin.ps1" @planArgs -CertificateThumbprint 'test' -Preview } 'requires ClientId'
    }
    Test-Case 'Receipt write failure still reports the created app ID and original cause' {
        function Invoke-FactoryGraph($Method='GET', $Uri, $Body) {
            if ($Method -eq 'GET') { return @{value=@()} }
            return @{id='recovery-app-id'}
        }
        $writer = (Get-Command Write-FactoryUploadReceipt).ScriptBlock
        function Write-FactoryUploadReceipt($Stream, $Receipt) {
            if ($Receipt.AppId) { throw 'Simulated disk failure' }
            & $writer $Stream $Receipt
        }
        $plan = Get-FactoryUploadPlan @planArgs
        Assert-Throws { Invoke-FactoryPublishPlan $plan '33333333-3333-3333-3333-333333333333' } "App ID: 'recovery-app-id'.*Simulated disk failure"
    }
    Test-Case 'Duplicate display names stop before any Graph write' {
        function Invoke-FactoryGraph($Method='GET', $Uri, $Body) {
            if ($Method -ne 'GET') { throw 'Unexpected Graph mutation' }
            return @{value=@(@{id='existing-id';displayName='7-Zip'})}
        }
        $plan = Get-FactoryUploadPlan @planArgs
        Assert-Throws { Invoke-FactoryPublishPlan $plan '44444444-4444-4444-4444-444444444444' } 'already exists'
    }
    Test-Case 'Expiring storage credentials are renewed before upload' {
        $script:renewed = $false
        function Invoke-FactoryGraph($Method='GET', $Uri, $Body) {
            if ($Method -eq 'POST' -and $Uri -match '/renewUpload$') { $script:renewed=$true; return }
            return @{uploadState='azureStorageUriRenewalSuccess';azureStorageUri='https://renewed.blob.core.windows.net/a?sig=fake';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        }
        $old = @{azureStorageUri='https://old.blob.core.windows.net/a?sig=fake';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddMinutes(4).ToString('o')}
        $new = Update-FactoryUploadLocation '/test' $old 1 -SasRenewalThresholdMinutes 5
        Assert-True ($script:renewed -and $new.azureStorageUri -match '//renewed\.') 'Expired SAS not renewed.'
    }
    Test-Case 'Zero retries performs exactly one storage attempt' {
        $probe = @{Calls=0}
        function Start-Sleep { }
        Assert-Throws { Invoke-FactoryBlobOperation -Operation { $probe.Calls++; throw 'Simulated storage failure' } -MaxRetries 0 -Name 'Upload block' } 'after 1 attempt'
        Assert-True ($probe.Calls -eq 1) 'Zero retries still retried storage.'
    }
    Test-Case 'Invalid metadata and exit code conflicts fail before publication' {
        $config = Get-Content "$projectRoot/apps/7zip/26.05/app.json" -Raw | ConvertFrom-Json
        $config.psadt.rebootExitCodes = @(0)
        $config | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
        Assert-Throws { Get-FactoryUploadPlan @planArgs } 'exit codes overlap'
        $config = Get-Content "$projectRoot/apps/7zip/26.05/app.json" -Raw | ConvertFrom-Json
        $config | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
        $bad = "$sandbox/bad.intunewin"
        Set-Content $bad 'Not a zip archive'
        Assert-Throws { Get-FactoryUploadPlan @planArgs -IntuneWinPath $bad } 'archive|directory|corrupt'
    }
} finally {
    $checked = [IO.Path]::GetFullPath($sandbox)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $checked.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $checked -Leaf) -notmatch '^IntuneAppFactory\.UploadTests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
Write-Host "Upload tests: $script:passed passed, $script:failed failed."
if ($script:failed) { throw 'Upload tests failed.' }
