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
        Assert-Throws { Get-FactoryUploadPlan -RevisionPath $sandbox } 'deployMode.*required|DeployMode.*required'
    }
    Test-Case 'JSON enum fields reject singleton arrays before Graph publication' {
        foreach ($field in @('deployMode','restartBehavior','returnCodeType','operationType','operator')) {
            $example = Get-Content "$projectRoot/examples/notepadplusplus.app.json" -Raw | ConvertFrom-Json
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
        $script:puts = [Collections.Generic.List[object]]::new()
        function Invoke-FactoryStoragePut($Uri, [byte[]]$Bytes, $ContentType) {
            $script:puts.Add(@{Uri=$Uri;Bytes=$Bytes.Clone();ContentType=$ContentType})
        }
        $location = @{azureStorageUri='https://test.blob.core.windows.net/c/b?sig=redacted';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/deviceAppManagement/mobileApps/test/files/test' -Location $location -TimeoutSeconds 10
        Assert-True ($script:puts.Count -eq 3) 'Expected two data blocks and one block list.'
        Assert-True ($script:puts[0].Bytes.Length -eq 4MB -and $script:puts[0].Bytes[0] -eq 42) 'Wrong first block.'
        Assert-True ($script:puts[1].Bytes.Length -eq 17 -and $script:puts[1].Bytes[-1] -eq 99) 'Final block was corrupted.'
        $list = [Text.Encoding]::UTF8.GetString($script:puts[2].Bytes)
        Assert-True ($list -match '<Latest>MDAwMDAwMDA=</Latest><Latest>MDAwMDAwMDE=</Latest>') 'Wrong ordered block list.'
        $script:puts.Clear()
        Send-FactoryEncryptedContent -Path $archivePath -FileUri '/test' -Location $location -TimeoutSeconds 10 -BlockSizeBytes 1MB -MaxRetries 0 -SasRenewalThresholdMinutes 5
        Assert-True ($script:puts.Count -eq 6 -and $script:puts[0].Bytes.Length -eq 1MB -and $script:puts[4].Bytes.Length -eq 17) 'Configured block size not used.'
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
        function Invoke-WebRequest { $probe.Calls++; return @{StatusCode=503} }
        function Start-Sleep { }
        Assert-Throws { Invoke-FactoryStoragePut -Uri 'https://test.blob.core.windows.net/a?sig=fake' -Bytes ([byte[]]@(1)) -MaxRetries 0 } 'after 1 attempt'
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
