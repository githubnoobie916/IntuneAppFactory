#requires -Version 5.1
# Build-time configuration and filesystem validation. Never shipped in a package.

function Assert-FactorySegment([string]$Value, [string]$Label) {
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Value.EndsWith('.') -or
        $Value -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') {
        throw "$Label must be a safe path segment (letters, digits, dots, underscores or hyphens; no device names)."
    }
}

function Get-FactoryPath([string]$Root, [string]$RelativePath) {
    # Reject traversal, drive/UNC paths, wildcards, ADS and Windows name aliases.
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '^[\\/]|[:*?"<>|\x00-\x1f]') {
        throw "Invalid relative path: '$RelativePath'."
    }
    foreach ($part in ($RelativePath -split '[\\/]')) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[ .]$|^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') {
            throw "Invalid relative path component in '$RelativePath'."
        }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its root: '$RelativePath'."
    }
    return $full
}

function Assert-FactoryNoLinks([string]$Path, [switch]$Recurse) {
    # Check ancestors too. OneDrive cloud placeholders have ReparsePoint metadata
    # but no LinkType; they do not redirect paths like junctions and symbolic links.
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.LinkType -in @('Junction','SymbolicLink')) { throw "Reparse points that redirect paths are not supported: '$current'." }
        }
        $current = Split-Path $current -Parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $full -PathType Container)) {
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($full)
        while ($pending.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                if ($item.LinkType -in @('Junction','SymbolicLink')) { throw "Reparse points that redirect paths are not supported: '$($item.FullName)'." }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            }
        }
    }
}

function Assert-FactoryObject($Value, [string[]]$Keys, [string]$Label, [string[]]$Required = $Keys) {
    if ($Value -isnot [pscustomobject]) { throw "$Label must be a JSON object." }
    foreach ($key in $Value.PSObject.Properties.Name) {
        if ($key -notin $Keys) { throw "Unknown property '$Label.$key'. Check README.md for supported settings." }
    }
    foreach ($key in $Required) {
        if ($key -notin $Value.PSObject.Properties.Name) { throw "Missing required setting '$Label.$key'. Specify it explicitly in JSON." }
    }
}

function Assert-FactoryText($Value, [string]$Label, [switch]$AllowEmpty) {
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) -or $Value -match '[\x00-\x1f]') {
        throw "$Label must be a valid string without control characters (empty is allowed only where documented)."
    }
}

function Read-FactoryConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedVersion, [string]$Revision)

    Assert-FactoryNoLinks $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: '$Path'." }
    try { $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
    Assert-FactoryObject $config @('name','publisher','version','architecture','language','revision','install','uninstall','repair','additionalFiles','psadt','intune','notes') 'app'
    foreach ($field in @('name','publisher','version','architecture','language','revision')) { Assert-FactoryText $config.$field "app.$field" }
    Assert-FactoryText $config.notes 'app.notes' -AllowEmpty
    Assert-FactorySegment $config.version 'app.version'
    if ($ExpectedVersion -and $config.version -cne $ExpectedVersion) { throw "Configuration version '$($config.version)' does not match selected version '$ExpectedVersion'." }
    if ($config.architecture -notin @('x86','x64','arm64')) { throw 'app.architecture must be x86, x64 or arm64.' }
    if ($config.revision -notmatch '^[0-9]{1,4}$') { throw 'app.revision must be a string of 1-4 digits.' }
    if ($Revision) {
        if ($Revision -notmatch '^[0-9]{1,4}$') { throw 'Revision must contain 1-4 digits.' }
        $config.revision = $Revision
    }
    if ($config.additionalFiles -isnot [array]) { throw 'app.additionalFiles must be an array.' }
    foreach ($file in $config.additionalFiles) {
        Assert-FactoryText $file 'app.additionalFiles[]'
        $null = Get-FactoryPath $PSScriptRoot $file
    }
    foreach ($action in @('install','uninstall','repair')) {
        if ($config.$action -isnot [array] -or ($action -ne 'repair' -and $config.$action.Count -eq 0)) {
            throw "app.$action must be an ordered array of steps; only repair may be empty."
        }
        $index = 0
        foreach ($step in $config.$action) {
            $label = "app.$action[$index]"
            Assert-FactoryObject $step @('type','path','productCode','executable','arguments') $label @('type','arguments')
            if ($step.type -notin @('MSI','EXE')) { throw "$label.type must be MSI or EXE." }
            Assert-FactoryText $step.arguments "$label.arguments" -AllowEmpty:($step.type -eq 'EXE')
            $selectors = @($step.PSObject.Properties.Name | Where-Object { $_ -in @('path','productCode','executable') })
            if ($selectors.Count -ne 1) { throw "$label must specify exactly one of path, productCode or executable." }
            $selector = $selectors[0]
            Assert-FactoryText $step.$selector "$label.$selector"
            if ($selector -eq 'path') {
                $null = Get-FactoryPath $PSScriptRoot $step.path
                if ([IO.Path]::GetExtension($step.path) -ine ".$($step.type)") { throw "$label.path must have the .$($step.type) extension." }
            }
            elseif ($action -eq 'install') { throw "$label requires path for installation." }
            elseif ($selector -eq 'productCode') {
                if ($step.type -ne 'MSI' -or $step.productCode -notmatch '^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$' -or [guid]$step.productCode -eq [guid]::Empty) {
                    throw "$label.productCode must be a nonzero MSI product GUID in braces."
                }
            }
            elseif ($step.type -ne 'EXE' -or $step.executable -notmatch '^(?:[A-Za-z]:[\\/]|%(?:ProgramFiles|ProgramFiles\(x86\)|ProgramW6432|ProgramData|LocalAppData|AppData|SystemRoot)%[\\/]).+\.exe$' -or
                    $step.executable -match '[*?"<>|]|(?:^|[\\/])\.\.?(?:[\\/]|$)' -or $step.executable.Substring(2).Contains(':')) {
                throw "$label.executable must be an absolute local EXE path or start with a supported %environment variable%."
            }
            if ($step.type -eq 'EXE' -and [IO.Path]::GetFileNameWithoutExtension($step.$selector) -in @('powershell','pwsh','cmd','wscript','cscript','mshta')) {
                throw "$label cannot invoke a script interpreter."
            }
            $index++
        }
    }

    $options = $config.psadt
    $optionKeys = @('processesToClose','closeProcesses','closeProcessesCountdown','allowDefer','deferTimes','checkDiskSpace','persistPrompt','suppressRebootPassThru','terminalServerMode','disableLogging','scriptAuthor','scriptVersion','scriptDate','successExitCodes','rebootExitCodes','installName','installTitle','completionPrompt')
    Assert-FactoryObject $options $optionKeys 'app.psadt' -Required @($optionKeys | Where-Object { $_ -ne 'closeProcessesCountdown' })
    foreach ($field in @('closeProcesses','allowDefer','checkDiskSpace','persistPrompt','suppressRebootPassThru','terminalServerMode','disableLogging')) {
        if ($options.$field -isnot [bool]) { throw "app.psadt.$field must be a JSON boolean." }
    }
    foreach ($field in @('deferTimes','closeProcessesCountdown')) {
        if ($field -notin $options.PSObject.Properties.Name) { continue }
        if (($options.$field -isnot [int] -and $options.$field -isnot [long]) -or $options.$field -lt 0 -or $options.$field -gt 86400) {
            throw "app.psadt.$field must be an integer between 0 and 86400."
        }
    }
    if ($options.allowDefer -and $options.deferTimes -lt 1) { throw 'app.psadt.deferTimes must be positive when deferral is enabled.' }
    foreach ($field in @('scriptAuthor','scriptVersion','scriptDate')) { Assert-FactoryText $options.$field "app.psadt.$field" }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($options.scriptDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { throw 'app.psadt.scriptDate must be a valid yyyy-MM-dd date.' }
    $version = $null
    if (-not [version]::TryParse($options.scriptVersion, [ref]$version)) { throw 'app.psadt.scriptVersion must be a valid dotted version.' }
    foreach ($field in @('installName','installTitle')) { Assert-FactoryText $options.$field "app.psadt.$field" -AllowEmpty }
    foreach ($field in @('successExitCodes','rebootExitCodes')) {
        if ($options.$field -isnot [array] -or $options.$field.Count -eq 0) { throw "app.psadt.$field must be a nonempty array of exit codes." }
        foreach ($code in $options.$field) {
            if (($code -isnot [int] -and $code -isnot [long]) -or $code -lt [int]::MinValue -or $code -gt [int]::MaxValue) { throw "app.psadt.$field must contain 32-bit integers." }
        }
    }
    if ($options.processesToClose -isnot [array]) { throw 'app.psadt.processesToClose must be an array.' }
    $names = @()
    foreach ($process in $options.processesToClose) {
        Assert-FactoryObject $process @('name','description') 'app.psadt.processesToClose[]'
        Assert-FactoryText $process.name 'app.psadt.processesToClose[].name'
        Assert-FactoryText $process.description 'app.psadt.processesToClose[].description'
        if ($process.name -notmatch '^[A-Za-z0-9][A-Za-z0-9_. -]*$' -or $process.name -match '\.exe$') { throw 'Process names must be literal names without .exe or wildcards.' }
        if ($process.name -in $names) { throw 'app.psadt.processesToClose contains duplicate process names.' }
        $names += $process.name
    }
    $prompt = $options.completionPrompt
    Assert-FactoryObject $prompt @('enabled','message','buttonRightText','noWait') 'app.psadt.completionPrompt'
    foreach ($field in @('enabled','noWait')) {
        if ($prompt.$field -isnot [bool]) { throw "app.psadt.completionPrompt.$field must be a JSON boolean." }
    }
    Assert-FactoryText $prompt.message 'app.psadt.completionPrompt.message' -AllowEmpty:(-not $prompt.enabled)
    Assert-FactoryText $prompt.buttonRightText 'app.psadt.completionPrompt.buttonRightText'

    Assert-FactoryObject $config.intune @('displayName','description','installContext','detection','icon','informationUrl','upload','displayVersion','developer','owner','privacyInformationUrl','notes','isFeatured','allowAvailableUninstall','categoryIds','roleScopeTagIds') 'app.intune' @('displayName','description','installContext','detection','icon')
    Assert-FactoryIntuneMetadata $config.intune
    if ('informationUrl' -in $config.intune.PSObject.Properties.Name) {
        Assert-FactoryText $config.intune.informationUrl 'app.intune.informationUrl' -AllowEmpty
        $informationUri = $null
        if ($config.intune.informationUrl -and (-not [uri]::TryCreate($config.intune.informationUrl, [UriKind]::Absolute, [ref]$informationUri) -or $informationUri.Scheme -ne 'https' -or $informationUri.UserInfo)) { throw 'app.intune.informationUrl must be an HTTPS URL without credentials, or empty.' }
    }
    if ('upload' -in $config.intune.PSObject.Properties.Name) { Assert-FactoryUploadConfig $config.intune.upload }
    Assert-FactoryText $config.intune.displayName 'app.intune.displayName'
    Assert-FactoryText $config.intune.description 'app.intune.description' -AllowEmpty
    if ($config.intune.installContext -notin @('system','user')) { throw 'app.intune.installContext must be system or user.' }
    Assert-FactoryText $config.intune.icon 'app.intune.icon' -AllowEmpty
    if ($config.intune.icon) {
        $null = Get-FactoryPath $PSScriptRoot $config.intune.icon
        if ([IO.Path]::GetExtension($config.intune.icon) -ine '.png') { throw 'app.intune.icon must be a relative PNG path at the application root, or empty.' }
    }
    if ($null -ne $config.intune.detection) {
        $detection = $config.intune.detection
        Assert-FactoryText $detection.type 'app.intune.detection.type'
        switch ($detection.type) {
            'powershell' {
                Assert-FactoryObject $detection @('type','scriptPath','runAs32Bit','enforceSignatureCheck') 'app.intune.detection'
                Assert-FactoryText $detection.scriptPath 'app.intune.detection.scriptPath'
                $null = Get-FactoryPath $PSScriptRoot $detection.scriptPath
                if ([IO.Path]::GetExtension($detection.scriptPath) -ine '.ps1') { throw 'Detection scriptPath must be a relative .ps1 path inside the application version directory.' }
                foreach ($field in @('runAs32Bit','enforceSignatureCheck')) {
                    if ($detection.$field -isnot [bool]) { throw "app.intune.detection.$field must be a JSON boolean." }
                }
            }
            'msi' {
                Assert-FactoryObject $detection @('type','productCode') 'app.intune.detection'
                if ($detection.productCode -notmatch '^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$' -or [guid]$detection.productCode -eq [guid]::Empty) { throw 'MSI detection requires a nonzero productCode GUID in braces.' }
            }
            'file' {
                Assert-FactoryObject $detection @('type','path','file','version') 'app.intune.detection'
                foreach ($field in @('path','file','version')) { Assert-FactoryText $detection.$field "app.intune.detection.$field" }
            }
            'registry' {
                Assert-FactoryObject $detection @('type','key','valueName','value','operationType','operator','check32BitOn64System') 'app.intune.detection' @('type','key','valueName','value')
                Assert-FactoryText $detection.key 'app.intune.detection.key'
                foreach ($field in @('valueName','value')) { Assert-FactoryText $detection.$field "app.intune.detection.$field" -AllowEmpty }
                Assert-FactoryRegistryDetectionOptions $detection
            }
            default { throw 'app.intune.detection.type must be msi, file, registry or powershell; use detection: null for no detection metadata.' }
        }
    }
    return $config
}

function Assert-FactoryUploadConfig($Upload) {
    $label = 'app.intune.upload'
    Assert-FactoryObject $Upload @('deployMode','minimumSupportedWindowsRelease','restartBehavior','returnCodes','transport','maxRunTimeInMinutes','minimumFreeDiskSpaceInMB','minimumMemoryInMB','minimumNumberOfProcessors','minimumCpuSpeedInMHz') $label @('minimumSupportedWindowsRelease','restartBehavior')
    if ('deployMode' -in $Upload.PSObject.Properties.Name) {
        Assert-FactoryText $Upload.deployMode "$label.deployMode"
        if ($Upload.deployMode -notin @('Auto','Silent','NonInteractive','Interactive')) { throw "$label.deployMode must be Auto, Silent, NonInteractive or Interactive." }
    }
    Assert-FactoryText $Upload.restartBehavior "$label.restartBehavior"
    Assert-FactoryWindowsRelease $Upload.minimumSupportedWindowsRelease
    foreach ($field in @('maxRunTimeInMinutes','minimumFreeDiskSpaceInMB','minimumMemoryInMB','minimumNumberOfProcessors','minimumCpuSpeedInMHz')) {
        if ($field -notin $Upload.PSObject.Properties.Name) { continue }
        $minimum = 0; $maximum = [int]::MaxValue
        if ($field -eq 'maxRunTimeInMinutes') { $minimum = 1; $maximum = 1440 }
        $value = $Upload.$field
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $minimum -or $value -gt $maximum) { throw "$label.$field must be an integer between $minimum and $maximum." }
    }
    if ($Upload.restartBehavior -notin @('basedOnReturnCode','suppress','allow','force')) { throw "$label.restartBehavior must be basedOnReturnCode, suppress, allow or force." }
    if ('returnCodes' -in $Upload.PSObject.Properties.Name) {
        if ($Upload.returnCodes -isnot [array] -or $Upload.returnCodes.Count -eq 0) { throw "$label.returnCodes must be a nonempty array." }
        $seen = @{}
        foreach ($entry in $Upload.returnCodes) {
            Assert-FactoryObject $entry @('returnCode','type') "$label.returnCodes[]"
            Assert-FactoryText $entry.type "$label.returnCodes[].type"
            if (($entry.returnCode -isnot [int] -and $entry.returnCode -isnot [long]) -or $entry.returnCode -lt [int]::MinValue -or $entry.returnCode -gt [int]::MaxValue) { throw "$label.returnCodes[].returnCode must be a 32-bit integer." }
            if ($entry.type -notin @('success','softReboot','hardReboot','retry','failed')) { throw "$label.returnCodes[].type is invalid." }
            if ($seen.ContainsKey([string]$entry.returnCode)) { throw "$label.returnCodes contains a duplicate returnCode." }
            $seen[[string]$entry.returnCode] = $true
        }
    }
    if ('transport' -in $Upload.PSObject.Properties.Name) {
        Assert-FactoryObject $Upload.transport @('maxRetries','blockSizeBytes','sasRenewalThresholdMinutes','timeoutSeconds') "$label.transport"
        $ranges = @{maxRetries=@(0,10);blockSizeBytes=@(1MB,16MB);sasRenewalThresholdMinutes=@(1,30);timeoutSeconds=@(1,7200)}
        foreach ($name in $ranges.Keys) {
            $value = $Upload.transport.$name
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $ranges[$name][0] -or $value -gt $ranges[$name][1]) { throw "$label.transport.$name must be an integer between $($ranges[$name][0]) and $($ranges[$name][1])." }
        }
    }
}

function Assert-FactoryWindowsRelease($Value) {
    # Graph values, not a shape-only regex: reject typos such as Windows11_24H1.
    $supported = @('1607','1703','1709','1803','1809','1903','1909','2004','20H2','21H1','21H2','22H2',
        'Windows11_21H2','Windows11_22H2','Windows11_23H2','Windows11_24H2','Windows11_25H2','Windows11_26H1','Windows11_26H2')
    if ($Value -isnot [string] -or $Value -cnotin $supported) {
        throw "minimumSupportedWindowsRelease must be a recognized Graph Windows release, for example 1809 or 22H2 (Windows 10), or Windows11_24H2. Allowed values: $($supported -join ', ')."
    }
}

function Assert-FactoryIntuneMetadata($Intune) {
    foreach ($field in @('displayVersion','developer','owner','notes','privacyInformationUrl')) {
        if ($field -in $Intune.PSObject.Properties.Name) {
            Assert-FactoryText $Intune.$field "app.intune.$field" -AllowEmpty:($field -ne 'displayVersion')
        }
    }
    if ($Intune.privacyInformationUrl) {
        $uri = $null
        if (-not [uri]::TryCreate($Intune.privacyInformationUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'app.intune.privacyInformationUrl must be an HTTPS URL without credentials, or empty.' }
    }
    foreach ($field in @('isFeatured','allowAvailableUninstall')) {
        if ($field -in $Intune.PSObject.Properties.Name -and $Intune.$field -isnot [bool]) { throw "app.intune.$field must be a JSON boolean." }
    }
    foreach ($field in @('categoryIds','roleScopeTagIds')) {
        if ($field -notin $Intune.PSObject.Properties.Name) { continue }
        if ($Intune.$field -isnot [array]) { throw "app.intune.$field must be an array of strings." }
        $seen = @{}
        foreach ($id in $Intune.$field) {
            Assert-FactoryText $id "app.intune.$field[]"
            if ($field -eq 'categoryIds') {
                $guid = [guid]::Empty
                if ($id -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -or -not [guid]::TryParse($id, [ref]$guid) -or $guid -eq [guid]::Empty) { throw 'app.intune.categoryIds must contain nonempty category GUIDs.' }
            } elseif ($id -notmatch '^(0|[1-9][0-9]*)$') { throw 'app.intune.roleScopeTagIds must contain numeric ID strings.' }
            if ($seen.ContainsKey($id)) { throw "app.intune.$field contains a duplicate ID." }
            $seen[$id] = $true
        }
    }
}

function Assert-FactoryRegistryDetectionOptions($Detection) {
    $fields = @($Detection.PSObject.Properties.Name)
    if (('operationType' -in $fields) -xor ('operator' -in $fields)) { throw 'Registry detection requires operationType and operator together.' }
    if ('check32BitOn64System' -in $fields -and $Detection.check32BitOn64System -isnot [bool]) { throw 'Registry detection.check32BitOn64System must be a JSON boolean.' }
    if ('operationType' -notin $fields) { return }
    Assert-FactoryText $Detection.operationType 'app.intune.detection.operationType'
    Assert-FactoryText $Detection.operator 'app.intune.detection.operator'
    if ($Detection.operationType -notin @('exists','doesNotExist','string','integer','version')) { throw 'Registry detection.operationType is invalid.' }
    if ($Detection.operationType -in @('exists','doesNotExist')) {
        if ($Detection.operator -ne 'notConfigured' -or $Detection.value -ne '') { throw 'Registry existence detection requires operator notConfigured and an empty value.' }
    } else {
        if ($Detection.operator -notin @('equal','notEqual','greaterThan','greaterThanOrEqual','lessThan','lessThanOrEqual')) { throw 'Registry detection.operator is invalid.' }
        if ($Detection.operationType -eq 'string' -and $Detection.operator -notin @('equal','notEqual')) { throw 'Registry string detection supports equal or notEqual.' }
        $version = $null; $number = 0L
        if ($Detection.operationType -eq 'version' -and -not [version]::TryParse($Detection.value, [ref]$version)) { throw 'Registry version detection requires a dotted numeric value.' }
        if ($Detection.operationType -eq 'integer' -and -not [long]::TryParse($Detection.value, [ref]$number)) { throw 'Registry integer detection requires an integer value encoded as a JSON string.' }
    }
}

function Read-FactoryDetectionScript([string]$Path) {
    Assert-FactoryNoLinks $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Detection script not found: '$Path'." }
    # A factory guard, not an Intune service limit. Never execute the script here.
    if ((Get-Item -LiteralPath $Path).Length -gt 1MB) { throw 'Detection script exceeds the factory limit of 1 MiB.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    try { $source = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF) }
    catch { throw 'Detection script must be saved as UTF-8 (preferably with BOM).' }
    if ([string]::IsNullOrWhiteSpace($source)) { throw 'Detection script must not be empty.' }
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "Detection script has PowerShell syntax errors: $($parseErrors[0].Message)" }
    return ,$bytes
}

function Get-FactoryBytesHash([byte[]]$Bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Bytes)).Replace('-', '') }
    finally { $hasher.Dispose() }
}
