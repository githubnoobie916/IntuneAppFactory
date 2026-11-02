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
    Test-Case 'Preview uses revision metadata and exposes no encryption secrets' {
        $plan = Get-FactoryUploadPlan @planArgs
        Assert-True ($plan.AppBody.installCommandLine -eq 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent') 'Wrong install command.'
        Assert-True ($plan.AppBody.rules[0].operationType -eq 'version') 'Missing version detection.'
        Assert-True ($plan.AppBody.rules[0].operator -eq 'greaterThanOrEqual') 'Wrong detection comparison.'
        Assert-True ($plan.FileBody.size -eq 12345 -and $plan.FileBody.sizeEncrypted -eq (4MB + 17)) 'Wrong inner content sizes.'
        Assert-True (($plan | ConvertTo-Json -Depth 20) -notmatch 'encryptionKey|macKey|azureStorageUri') 'Secret in preview.'
    }
    Test-Case 'Null detection is rejected before contacting Intune' {
        $config.intune.detection = $null
        $config | ConvertTo-Json -Depth 20 | Set-Content "$sandbox/app.json"
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
} finally {
    $checked = [IO.Path]::GetFullPath($sandbox)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $checked.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $checked -Leaf) -notmatch '^IntuneAppFactory\.UploadTests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
Write-Host "Upload tests: $script:passed passed, $script:failed failed."
if ($script:failed) { throw 'Upload tests failed.' }
