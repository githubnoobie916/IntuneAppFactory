#requires -Version 7.2
# Publishing helpers only; never copied into the deployment package.
. "$PSScriptRoot/IntuneWin.ps1"

function Invoke-FactoryGraph {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    if ($Uri.StartsWith('/')) { $Uri = 'https://graph.microsoft.com/v1.0' + $Uri }
    $target = [uri]$Uri
    if ($target.Scheme -ne 'https' -or $target.Host -ne 'graph.microsoft.com' -or -not $target.AbsolutePath.StartsWith('/v1.0/deviceAppManagement/')) { throw 'Unexpected Graph endpoint.' }
    $request = @{ Method=$Method; Uri=$Uri; OutputType='PSObject'; ErrorAction='Stop'; Verbose=$false; Debug=$false }
    if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $request.ContentType = 'application/json' }
    try { Invoke-MgGraphRequest @request }
    catch {
        # Do not echo responses or request bodies: file metadata contains encryption keys.
        $status = $_.Exception.Response.StatusCode
        throw "Graph $Method failed (HTTP $status). Check permissions, connectivity, and the upload receipt; no automatic rollback was performed."
    }
}

function Wait-FactoryUploadState {
    param([string]$Uri, [string]$ExpectedState, [int]$TimeoutSeconds = 900, [int]$PollSeconds = 5)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $file = Invoke-FactoryGraph -Uri $Uri
        if ($file.uploadState -eq $ExpectedState) { return $file }
        if ($file.uploadState -match 'Failed$|TimedOut$|^error$') { throw "Intune content operation failed: $($file.uploadState)." }
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, $TimeoutSeconds))
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out waiting for Intune content state $ExpectedState."
}

function Assert-FactoryStorageUri([string]$Uri) {
    $target = $null
    if (-not [uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$target) -or $target.Scheme -ne 'https' -or
        $target.Host -notmatch '^[a-z0-9]+\.blob\.core\.windows\.net$' -or $target.Port -ne 443 -or
        $target.UserInfo -or -not $target.Query -or $target.Fragment) { throw 'Expected an Azure Blob HTTPS upload URI for the public cloud.' }
}

function Invoke-FactoryStoragePut {
    param([string]$Uri, [byte[]]$Bytes, [string]$ContentType = 'application/octet-stream')
    Assert-FactoryStorageUri $Uri
    # PUT of the same block ID or block list is safe to retry after a lost response.
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $response = $null
        try {
            $response = Invoke-WebRequest -Method Put -Uri $Uri -Body $Bytes -ContentType $ContentType `
                -Headers @{'x-ms-version'='2021-12-02'} -TimeoutSec 120 -MaximumRedirection 0 `
                -SkipHttpErrorCheck -ErrorAction Stop -Verbose:$false -Debug:$false
        } catch { } # The native exception may contain the SAS URI; never propagate it.
        if ($response -and [int]$response.StatusCode -eq 201) { return }
        if ($response -and [int]$response.StatusCode -notin @(408,429,500,502,503,504)) {
            throw "Azure Blob upload failed (HTTP $([int]$response.StatusCode)); SAS details omitted."
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([Math]::Pow(2, $attempt + 1)) }
    }
    throw 'Azure Blob upload failed after four attempts; SAS details omitted.'
}

function Update-FactoryUploadLocation {
    param([string]$FileUri, $Location, [int]$TimeoutSeconds)
    if (-not $Location.azureStorageUriExpirationDateTime) { throw 'Intune did not provide a SAS expiration time.' }
    if ([DateTimeOffset]::Parse($Location.azureStorageUriExpirationDateTime) -lt [DateTimeOffset]::UtcNow.AddMinutes(3)) {
        $null = Invoke-FactoryGraph -Method POST -Uri "$FileUri/renewUpload" -Body @{}
        $Location = Wait-FactoryUploadState -Uri $FileUri -ExpectedState 'azureStorageUriRenewalSuccess' -TimeoutSeconds $TimeoutSeconds
    }
    Assert-FactoryStorageUri $Location.azureStorageUri
    return $Location
}

function Send-FactoryEncryptedContent {
    param([string]$Path, [string]$FileUri, $Location, [int]$TimeoutSeconds = 900)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('IntuneWinPackage/Contents/IntunePackage.intunewin')
        if (-not $entry -or $entry.Length -le 0) { throw 'Encrypted payload is missing.' }
        $stream = $entry.Open()
        try {
            $blocks = [Collections.Generic.List[string]]::new()
            $buffer = [byte[]]::new(4MB)
            $total = 0L
            while ($total -lt $entry.Length) {
                $count = 0
                while ($count -lt $buffer.Length) {
                    $read = $stream.Read($buffer, $count, $buffer.Length - $count)
                    if ($read -eq 0) { break }
                    $count += $read
                }
                if ($count -eq 0) { throw 'Unexpected end of encrypted content.' }
                if ($blocks.Count -ge 50000) { throw 'Encrypted content exceeds the block upload limit.' }
                $Location = Update-FactoryUploadLocation $FileUri $Location $TimeoutSeconds
                $block = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($blocks.Count.ToString('D8')))
                $data = [byte[]]::new($count)
                [Array]::Copy($buffer, $data, $count)
                Invoke-FactoryStoragePut -Uri ($Location.azureStorageUri + '&comp=block&blockid=' + [uri]::EscapeDataString($block)) -Bytes $data
                $blocks.Add($block); $total += $count
                Write-Progress -Activity 'Uploading encrypted Intune content' -Status "$total / $($entry.Length) bytes" -PercentComplete (100 * $total / $entry.Length)
            }
            $Location = Update-FactoryUploadLocation $FileUri $Location $TimeoutSeconds
            $xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($blocks | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
            Invoke-FactoryStoragePut -Uri ($Location.azureStorageUri + '&comp=blocklist') -Bytes ([Text.Encoding]::UTF8.GetBytes($xml)) -ContentType 'application/xml'
        } finally { $stream.Dispose(); Write-Progress -Activity 'Uploading encrypted Intune content' -Completed }
    } finally { $archive.Dispose() }
}

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

function Write-FactoryUploadReceipt([IO.FileStream]$Stream, $Receipt) {
    $Receipt.UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json -Depth 10))
    $Stream.Position = 0
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.SetLength($bytes.Length)
    $Stream.Flush($true)
}

function Invoke-FactoryPublishPlan {
    param($Plan, [guid]$TenantId, [int]$TimeoutSeconds = 900)
    $receiptPath = Get-FactoryPath $Plan.RevisionPath "upload-$TenantId.json"
    Assert-FactoryNoLinks $receiptPath
    if (Test-Path -LiteralPath $receiptPath) { throw "Upload receipt already exists: '$receiptPath'. Review its app ID and tenant state before retrying; see UPLOADING.md." }
    # CreateNew both serializes local runs and prevents an unexamined repeat after a crash.
    $receiptStream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    $receipt = [ordered]@{
        Status='InProgress'; Stage='CheckingDuplicates'; TenantId=$TenantId.ToString(); AppId=$null
        ContentVersionId=$null; FileId=$null; SHA256=$Plan.SHA256; IntuneWinPath=$Plan.IntuneWinPath
        DisplayName=$Plan.AppBody.displayName; Assignments=@(); UpdatedUtc=$null
    }
    try {
        Write-FactoryUploadReceipt $receiptStream $receipt
        $filter = [uri]::EscapeDataString("displayName eq '" + $Plan.AppBody.displayName.Replace("'", "''") + "'")
        $next = '/deviceAppManagement/mobileApps?$filter=' + $filter + '&$select=id,displayName'
        do {
            $page = Invoke-FactoryGraph -Uri $next
            if (@($page.value).Count -gt 0) { throw 'An app with this display name already exists. This uploader creates new apps only; review the existing app in Intune.' }
            $next = $page.'@odata.nextLink'
        } while ($next)
        $receipt.Stage = 'CreatingApp'; Write-FactoryUploadReceipt $receiptStream $receipt
        $app = Invoke-FactoryGraph -Method POST -Uri '/deviceAppManagement/mobileApps' -Body $Plan.AppBody
        if (-not $app.id) { throw 'Create app returned no ID. Inspect Intune before retrying.' }
        $receipt.AppId = [string]$app.id
        $receipt.Stage = 'CreatingContentVersion'; Write-FactoryUploadReceipt $receiptStream $receipt
        Write-Host "Created Intune app: $($receipt.AppId)"
        $appUri = '/deviceAppManagement/mobileApps/' + [uri]::EscapeDataString($receipt.AppId)
        $contentUri = "$appUri/microsoft.graph.win32LobApp/contentVersions"
        $version = Invoke-FactoryGraph -Method POST -Uri $contentUri -Body @{'@odata.type'='#microsoft.graph.mobileAppContent'}
        if (-not $version.id) { throw 'Create content version returned no ID.' }
        $receipt.ContentVersionId = [string]$version.id
        $receipt.Stage = 'CreatingContentFile'; Write-FactoryUploadReceipt $receiptStream $receipt
        $file = Invoke-FactoryGraph -Method POST -Uri ($contentUri + '/' + [uri]::EscapeDataString($receipt.ContentVersionId) + '/files') -Body $Plan.FileBody
        if (-not $file.id) { throw 'Create content file returned no ID.' }
        $receipt.FileId = [string]$file.id
        $fileUri = $contentUri + '/' + [uri]::EscapeDataString($receipt.ContentVersionId) + '/files/' + [uri]::EscapeDataString($receipt.FileId)
        $receipt.Stage = 'UploadingContent'; Write-FactoryUploadReceipt $receiptStream $receipt
        $location = Wait-FactoryUploadState -Uri $fileUri -ExpectedState 'azureStorageUriRequestSuccess' -TimeoutSeconds $TimeoutSeconds
        Send-FactoryEncryptedContent -Path $Plan.IntuneWinPath -FileUri $fileUri -Location $location -TimeoutSeconds $TimeoutSeconds
        $receipt.Stage = 'CommittingFile'; Write-FactoryUploadReceipt $receiptStream $receipt
        $metadata = Read-FactoryUploadArchive $Plan.IntuneWinPath
        $null = Invoke-FactoryGraph -Method POST -Uri "$fileUri/commit" -Body @{fileEncryptionInfo=$metadata.EncryptionInfo}
        $committed = Wait-FactoryUploadState -Uri $fileUri -ExpectedState 'commitFileSuccess' -TimeoutSeconds $TimeoutSeconds
        if (-not $committed.isCommitted) { throw 'Intune did not confirm the content file as committed.' }
        $receipt.Stage = 'PublishingApp'; Write-FactoryUploadReceipt $receiptStream $receipt
        $null = Invoke-FactoryGraph -Method PATCH -Uri $appUri -Body @{'@odata.type'='#microsoft.graph.win32LobApp'; committedContentVersion=$receipt.ContentVersionId}
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $published = Invoke-FactoryGraph -Uri $appUri
            if ($published.publishingState -eq 'published' -and [string]$published.committedContentVersion -eq $receipt.ContentVersionId) { break }
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Timed out waiting for the app to be published. Inspect the app before retrying.' }
            Start-Sleep -Seconds ([Math]::Min(5, $TimeoutSeconds))
        } while ($true)
        $receipt.Status = 'Published'; $receipt.Stage = 'Published'; Write-FactoryUploadReceipt $receiptStream $receipt
        foreach ($assignment in $Plan.Assignments) {
            $receipt.Stage = 'AssigningGroup'; Write-FactoryUploadReceipt $receiptStream $receipt
            $created = Invoke-FactoryGraph -Method POST -Uri "$appUri/assignments" -Body $assignment
            if (-not $created.id) { throw 'Assignment returned no ID. Verify assignments in Intune before retrying.' }
            $receipt.Assignments += @{Id=[string]$created.id; GroupId=$assignment.target.groupId; Intent=$assignment.intent}
        }
        $receipt.Stage = 'Complete'; Write-FactoryUploadReceipt $receiptStream $receipt
        return [pscustomobject]@{Status='Published'; AppId=$receipt.AppId; TenantId=$TenantId; ReceiptPath=$receiptPath; Assignments=$receipt.Assignments}
    } catch {
        $failureMessage = $_.Exception.Message
        $receipt.Status = 'Failed'
        try { Write-FactoryUploadReceipt $receiptStream $receipt }
        catch { Write-Warning 'Could not persist the failure receipt. Keep the app ID from the error and inspect Intune before retrying.' }
        throw "Upload stopped during $($receipt.Stage). App ID: '$($receipt.AppId)'. Receipt: '$receiptPath'. $failureMessage"
    } finally { $receiptStream.Dispose() }
}
