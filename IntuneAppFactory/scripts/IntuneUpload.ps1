#requires -Version 7.2
# Publishing helpers only; never copied into the deployment package.
. "$PSScriptRoot/IntuneWin.ps1"

function Read-FactoryUploadArchive([string]$Path) {
    Assert-FactoryIntuneWinArchive $Path 'Invoke-AppDeployToolkit.exe'
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if (@($archive.Entries | Where-Object FullName -eq 'IntuneWinPackage/Metadata/Detection.xml').Count -ne 1 -or
            @($archive.Entries | Where-Object FullName -eq 'IntuneWinPackage/Contents/IntunePackage.intunewin').Count -ne 1) { throw 'Duplicate archive entries are not supported.' }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.CloseInput = $true
        $settings.MaxCharactersInDocument = 1MB
        $reader = [Xml.XmlReader]::Create($archive.GetEntry('IntuneWinPackage/Metadata/Detection.xml').Open(), $settings)
        try { $doc = [Xml.XmlDocument]::new(); $doc.XmlResolver = $null; $doc.Load($reader) }
        finally { $reader.Dispose() }
        $encryption = @{}
        foreach ($field in @('encryptionKey','macKey','initializationVector','mac','fileDigest')) {
            $value = [string]$doc.ApplicationInfo.EncryptionInfo.$field
            $length = if ($field -eq 'initializationVector') { 16 } else { 32 }
            try { $valid = ([Convert]::FromBase64String($value).Length -eq $length) } catch { $valid = $false }
            if (-not $valid) { throw "Invalid archive encryption metadata: $field." }
            $encryption[$field] = $value
        }
        if ($doc.ApplicationInfo.EncryptionInfo.ProfileIdentifier -cne 'ProfileVersion1' -or
            $doc.ApplicationInfo.EncryptionInfo.FileDigestAlgorithm -cne 'SHA256') { throw 'Unsupported archive encryption profile or digest algorithm.' }
        $encryption.profileIdentifier = 'ProfileVersion1'
        $encryption.fileDigestAlgorithm = 'SHA256'
        return @{
            EncryptionInfo = $encryption
            FileBody = @{
                '@odata.type' = '#microsoft.graph.mobileAppContentFile'
                name = 'IntunePackage.intunewin'
                size = [long]$doc.ApplicationInfo.UnencryptedContentSize
                sizeEncrypted = $archive.GetEntry('IntuneWinPackage/Contents/IntunePackage.intunewin').Length
                isDependency = $false
            }
        }
    } finally { $archive.Dispose() }
}

function ConvertTo-FactoryDetectionRule($Detection, [string]$Architecture) {
    if ($null -eq $Detection) { throw 'Publishing requires non-null intune.detection metadata.' }
    $rule = @{ ruleType = 'detection' }
    switch ($Detection.type) {
        'msi' {
            $rule['@odata.type'] = '#microsoft.graph.win32LobAppProductCodeRule'
            $rule.productCode = $Detection.productCode
            $rule.productVersionOperator = 'notConfigured'
        }
        'file' {
            $parsed = $null
            if (-not [version]::TryParse($Detection.version, [ref]$parsed)) { throw 'File detection.version must be a numeric file version.' }
            $rule['@odata.type'] = '#microsoft.graph.win32LobAppFileSystemRule'
            $rule.path = $Detection.path; $rule.fileOrFolderName = $Detection.file
            $rule.check32BitOn64System = ($Architecture -eq 'x86')
            $rule.operationType = 'version'; $rule.operator = 'greaterThanOrEqual'
            $rule.comparisonValue = $Detection.version
        }
        'registry' {
            if ($Detection.key -notmatch '^HKEY_(LOCAL_MACHINE|CURRENT_USER)\\') { throw 'Registry detection.key must start with HKEY_LOCAL_MACHINE\ or HKEY_CURRENT_USER\.' }
            $rule['@odata.type'] = '#microsoft.graph.win32LobAppRegistryRule'
            $rule.keyPath = $Detection.key; $rule.valueName = $Detection.valueName
            $rule.check32BitOn64System = ($Architecture -eq 'x86')
            $rule.operationType = 'string'; $rule.operator = 'equal'; $rule.comparisonValue = $Detection.value
        }
        default { throw 'Unsupported detection type.' }
    }
    return $rule
}

function Get-FactoryUploadPlan {
    param(
        [Parameter(Mandatory)][string]$RevisionPath,
        [string]$IntuneWinPath,
        [Parameter(Mandatory)][ValidateSet('Silent','NonInteractive','Interactive')][string]$DeployMode,
        [Parameter(Mandatory)][ValidatePattern('^(Windows11_)?[0-9]{2}H[12]$')][string]$MinimumSupportedWindowsRelease,
        [Parameter(Mandatory)][ValidateSet('basedOnReturnCode','suppress','allow','force')][string]$RestartBehavior
    )
    $RevisionPath = Resolve-FactoryIntuneWinPath $RevisionPath
    Assert-FactoryNoLinks $RevisionPath
    $buildPath = Get-FactoryPath $RevisionPath 'build.json'
    Assert-FactoryNoLinks $buildPath
    $build = Get-Content -LiteralPath $buildPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($build.factory -ne 'IntuneAppFactory') { throw 'Select a generated IntuneAppFactory revision directory.' }
    $config = Read-FactoryConfig -Path (Get-FactoryPath $RevisionPath 'app.json') -ExpectedVersion $build.version
    if ($config.revision -cne $build.revision) { throw 'The app.json and build.json revisions do not match.' }
    $detection = ConvertTo-FactoryDetectionRule $config.intune.detection $config.architecture
    if (($config.intune | ConvertTo-Json -Depth 10 -Compress) -cne ($build.intune | ConvertTo-Json -Depth 10 -Compress)) { throw 'Intune metadata differs between app.json and build.json. Regenerate a consistent revision.' }
    foreach ($action in @('install','uninstall')) {
        $expected = 'Invoke-AppDeployToolkit.exe -DeploymentType ' + (Get-Culture).TextInfo.ToTitleCase($action)
        if ($build."${action}Command" -cne $expected) { throw 'Unsupported build commands. Regenerate with the current factory before uploading.' }
    }
    if (-not $IntuneWinPath) { $IntuneWinPath = Get-FactoryPath $RevisionPath 'IntuneWin/Invoke-AppDeployToolkit.intunewin' }
    $IntuneWinPath = Resolve-FactoryIntuneWinPath $IntuneWinPath
    Assert-FactoryNoLinks $IntuneWinPath
    if ([IO.Path]::GetExtension($IntuneWinPath) -ine '.intunewin') { throw 'IntuneWinPath must be an .intunewin file.' }
    $archive = Read-FactoryUploadArchive $IntuneWinPath
    $codes = [ordered]@{}
    foreach ($code in $config.psadt.successExitCodes) { $codes[[string]$code] = 'success' }
    foreach ($code in $config.psadt.rebootExitCodes) {
        if ($codes.Contains([string]$code)) { throw 'Success and reboot exit codes overlap.' }
        $codes[[string]$code] = if ($code -eq 1641) { 'hardReboot' } else { 'softReboot' }
    }
    if (-not $codes.Contains('1618')) { $codes['1618'] = 'retry' }
    if (-not $codes.Contains('1603')) { $codes['1603'] = 'failed' }
    $body = @{
        '@odata.type' = '#microsoft.graph.win32LobApp'
        displayName = $config.intune.displayName; description = $config.intune.description; publisher = $config.publisher
        notes = "IntuneAppFactory: $($build.appName) $($build.version) revision $($build.revision)"
        fileName = [IO.Path]::GetFileName($IntuneWinPath); setupFilePath = 'Invoke-AppDeployToolkit.exe'
        installCommandLine = $build.installCommand + " -DeployMode $DeployMode"
        uninstallCommandLine = $build.uninstallCommand + " -DeployMode $DeployMode"
        applicableArchitectures = 'none'; allowedArchitectures = $config.architecture
        minimumSupportedWindowsRelease = $MinimumSupportedWindowsRelease
        installExperience = @{ runAsAccount = $config.intune.installContext; deviceRestartBehavior = $RestartBehavior }
        rules = @($detection)
        returnCodes = @($codes.Keys | ForEach-Object { @{ returnCode = [int]$_; type = $codes[$_] } })
    }
    if ($build.icon) {
        $icon = Get-FactoryPath $RevisionPath $build.icon
        Assert-FactoryNoLinks $icon
        $iconBytes = [IO.File]::ReadAllBytes($icon)
        if ($iconBytes.Length -lt 8 -or [Convert]::ToHexString($iconBytes[0..7]) -ne '89504E470D0A1A0A') { throw 'The build icon must be a PNG file.' }
        $body.largeIcon = @{ type = 'image/png'; value = [Convert]::ToBase64String($iconBytes) }
    }
    return [pscustomobject]@{
        RevisionPath = $RevisionPath; IntuneWinPath = $IntuneWinPath
        SHA256 = (Get-FileHash -LiteralPath $IntuneWinPath -Algorithm SHA256).Hash
        AppBody = $body; FileBody = $archive.FileBody
        Assignments = @()
    }
}
