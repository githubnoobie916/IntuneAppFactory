#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$script:passed = 0
$script:failed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-ExpectedError([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { return $_.Exception.Message }
    throw 'Expected an error but the operation succeeded.'
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $_" }
}
. "$projectRoot/scripts/IntuneUpload.ps1"

function Invoke-TestPublishResponse($Method, $Uri, $Body) {
    $script:graphProbe.Calls.Add(@{Method=$Method;Uri=$Uri;Body=$Body})
    if ($Method -eq 'GET' -and $Uri -match '/mobileAppCategories/') {
        if ($script:graphProbe.MissingCategory) { throw 'Category not found (404).' }
        return @{id=$script:categoryId}
    }
    if ($Method -eq 'GET' -and $Uri -match '/mobileApps\?') { return @{value=@()} }
    if ($Method -eq 'POST' -and $Uri -eq '/deviceAppManagement/mobileApps') { return @{id='app-id'} }
    if ($Method -eq 'POST' -and $Uri -match '/contentVersions$') { return @{id='1'} }
    if ($Method -eq 'POST' -and $Uri -match '/files$') { return @{id='file-id'} }
    if ($Method -eq 'POST' -and $Uri -match '/commit$') { $script:graphProbe.Committed=$true; return }
    if ($Method -eq 'GET' -and $Uri -match '/files/file-id$') {
        if ($script:graphProbe.Committed) { return @{uploadState='commitFileSuccess';isCommitted=$true} }
        return @{uploadState='azureStorageUriRequestSuccess';azureStorageUri='https://test.blob.core.windows.net/c/b?sig=fake'}
    }
    if ($Method -eq 'PATCH' -and $Uri -eq '/deviceAppManagement/mobileApps/app-id') { return }
    if ($Method -eq 'GET' -and $Uri -eq '/deviceAppManagement/mobileApps/app-id') { return @{publishingState='published';committedContentVersion='1'} }
    if ($Method -eq 'POST' -and $Uri -match '/categories/\$ref$') {
        if ($script:graphProbe.FailCategory) { throw 'Category update rejected (403).' }
        return
    }
    if ($Method -eq 'GET' -and $Uri -match '/categories(?:\?|$)') {
        if ($script:graphProbe.OmitCategory) { return @{value=@()} }
        return @{value=@(@{id=$script:categoryId})}
    }
    if ($Method -eq 'POST' -and $Uri -match '/assignments$') {
        if ($script:graphProbe.FailAssignment) { throw 'Assignment update rejected (403).' }
        return @{id='assignment-id'}
    }
    throw "Unexpected Graph operation in test: $Method $Uri"
}
function New-TestPublishProbe {
    return @{Calls=[Collections.Generic.List[object]]::new();Committed=$false;FailCategory=$false;OmitCategory=$false;MissingCategory=$false;FailAssignment=$false}
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('IntuneAppFactory.GraphTests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:categoryId = '12345678-1234-1234-1234-123456789abc'
$plan = [pscustomobject]@{
    RevisionPath=$sandbox; IntuneWinPath="$sandbox/test.intunewin"; SHA256=('A' * 64); ApiVersion='beta'
    AppBody=@{displayName='Graph boundary test'}; FileBody=@{name='IntunePackage.intunewin';size=100;sizeEncrypted=128}
    Transport=@{TimeoutSeconds=1;BlockSizeBytes=4MB;MaxRetries=0;SasRenewalThresholdMinutes=3}
    CategoryIds=@($script:categoryId)
    CategoryOperations=@(@{Method='POST';Uri='/deviceAppManagement/mobileApps/{appId}/categories/$ref';Body=@{'@odata.id'="https://graph.microsoft.com/beta/deviceAppManagement/mobileAppCategories/$script:categoryId"}})
    Assignments=@(@{intent='available';target=@{groupId='55555555-5555-5555-5555-555555555555'}})
}
try {
    Test-Case 'Graph requests use beta and preserve JSON types and nested values' {
        $probe = @{Request=$null}
        function Invoke-MgGraphRequest {
            [CmdletBinding()]param($Method,$Uri,$Body,$ContentType,$OutputType)
            $probe.Request=$PSBoundParameters
            return @{id='created-id'}
        }
        $result = Invoke-FactoryGraph -Method POST -Uri '/deviceAppManagement/mobileApps' -Body @{displayName='A "quoted" name';isFeatured=$false;installExperience=@{maxRunTimeInMinutes=15}}
        Assert-True ($result.id -eq 'created-id') 'Graph result was lost.'
        Assert-True ($probe.Request.Uri -ceq 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps') 'Relative Graph path did not use beta.'
        Assert-True ($probe.Request.Method -eq 'POST' -and $probe.Request.ContentType -eq 'application/json') 'JSON request method or content type changed.'
        $body = $probe.Request.Body | ConvertFrom-Json
        Assert-True ($body.displayName -ceq 'A "quoted" name' -and $body.isFeatured -ceq $false -and $body.installExperience.maxRunTimeInMinutes -eq 15) 'JSON values were changed.'
    }
    foreach ($uri in @(
        'https://evil.example/beta/deviceAppManagement/mobileApps',
        'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps',
        'http://graph.microsoft.com/beta/deviceAppManagement/mobileApps',
        'https://user:password@graph.microsoft.com/beta/deviceAppManagement/mobileApps',
        'https://graph.microsoft.com:444/beta/deviceAppManagement/mobileApps',
        'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps#fragment'
    )) {
        Test-Case "Graph rejects unauthorized endpoint $uri" {
            $probe = @{Calls=0}
            function Invoke-MgGraphRequest { $probe.Calls++; throw 'Unexpected network request' }
            $message = Get-ExpectedError { Invoke-FactoryGraph -Uri $uri }
            Assert-True ($probe.Calls -eq 0 -and $message -match 'endpoint|URI|URL') 'Endpoint was not rejected locally.'
        }
    }
    Test-Case 'Structured Graph errors retain diagnostics and redact credentials and encryption values' {
        $requestId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $encryption = @{encryptionKey='secretEncryptionValue';macKey='secretMacKeyValue';initializationVector='secretIvValue';mac='secretMacValue';fileDigest='secretDigestValue'}
        $serviceMessage = 'Minimum release invalid. https://storage.blob.core.windows.net/c/b?sig=secretSasValue Bearer secretBearerValue ' + ($encryption.Values -join ' ')
        $detail = @{error=@{code='BadRequest';message=$serviceMessage;innerError=@{'request-id'=$requestId}}} | ConvertTo-Json -Depth 10
        function Invoke-MgGraphRequest {
            $exception = [Net.Http.HttpRequestException]::new('Untrusted transport details', $null, [Net.HttpStatusCode]::BadRequest)
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{StatusCode=400})
            $record = [Management.Automation.ErrorRecord]::new($exception,'GraphFailure',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
            $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($detail)
            throw $record
        }
        $message = Get-ExpectedError { Invoke-FactoryGraph -Method POST -Uri '/deviceAppManagement/mobileApps/app-id/contentVersions/1/files/file-id/commit' -Body @{fileEncryptionInfo=$encryption} }
        foreach ($expected in @('BadRequest','Minimum release invalid',$requestId,'POST','/deviceAppManagement/mobileApps/app-id/contentVersions/1/files/file-id/commit','400')) {
            Assert-True ($message.Contains($expected)) "Useful Graph diagnostic '$expected' was lost."
        }
        foreach ($secret in @('secretSasValue','secretBearerValue','https://storage.blob.core.windows.net') + @($encryption.Values)) {
            Assert-True (-not $message.Contains($secret)) "Graph error leaked '$secret'."
        }
    }
    Test-Case 'Category relationships are applied and verified after content publication before assignments' {
        $script:graphProbe = New-TestPublishProbe
        function Invoke-FactoryGraph($Method='GET',$Uri,$Body) { Invoke-TestPublishResponse $Method $Uri $Body }
        function Read-FactoryUploadArchive { @{EncryptionInfo=@{encryptionKey='fake'}} }
        function Send-FactoryEncryptedContent { }
        $tenant = '11111111-1111-1111-1111-111111111111'
        $result = Invoke-FactoryPublishPlan -Plan $plan -TenantId $tenant
        $receipt = Get-Content $result.ReceiptPath -Raw | ConvertFrom-Json
        Assert-True ($result.Status -eq 'Published' -and $receipt.ContentPublished -ceq $true -and $receipt.Status -eq 'Published') 'Published content was not recorded.'
        Assert-True ($receipt.CategoryIds.Count -eq 1 -and $receipt.CategoryIds[0] -ceq $script:categoryId) 'Receipt lost configured categories.'
        $calls = @($script:graphProbe.Calls)
        $categoryWrites = @($calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/categories/\$ref$' })
        Assert-True ($categoryWrites.Count -eq 1) 'Category relationship was not created exactly once.'
        Assert-True ($categoryWrites[0].Body.'@odata.id' -ceq "https://graph.microsoft.com/beta/deviceAppManagement/mobileAppCategories/$script:categoryId") 'Category reference URL is incorrect.'
        $publishIndex = [Array]::FindIndex($calls, [Predicate[object]]{param($call) $call.Method -eq 'GET' -and $call.Uri -eq '/deviceAppManagement/mobileApps/app-id'})
        $categoryWriteIndex = [Array]::FindIndex($calls, [Predicate[object]]{param($call) $call.Method -eq 'POST' -and $call.Uri -match '/categories/\$ref$'})
        $categoryVerifyIndex = [Array]::FindIndex($calls, [Predicate[object]]{param($call) $call.Method -eq 'GET' -and $call.Uri -match '/categories(?:\?|$)'})
        $assignmentIndex = [Array]::FindIndex($calls, [Predicate[object]]{param($call) $call.Method -eq 'POST' -and $call.Uri -match '/assignments$'})
        Assert-True ($publishIndex -ge 0 -and $categoryWriteIndex -gt $publishIndex -and $categoryVerifyIndex -gt $categoryWriteIndex -and $assignmentIndex -gt $categoryVerifyIndex) 'Category/assignment sequencing did not verify published settings.'
    }
    foreach ($scenario in @('FailCategory','OmitCategory','FailAssignment')) {
        Test-Case "$scenario preserves published-content status in a failed receipt" {
            $script:graphProbe = New-TestPublishProbe
            $script:graphProbe[$scenario] = $true
            function Invoke-FactoryGraph($Method='GET',$Uri,$Body) { Invoke-TestPublishResponse $Method $Uri $Body }
            function Read-FactoryUploadArchive { @{EncryptionInfo=@{encryptionKey='fake'}} }
            function Send-FactoryEncryptedContent { }
            $tenant = [guid]::NewGuid().ToString()
            $message = Get-ExpectedError { Invoke-FactoryPublishPlan -Plan $plan -TenantId $tenant }
            $receipt = Get-Content "$sandbox/upload-$tenant.json" -Raw | ConvertFrom-Json
            Assert-True ($receipt.ContentPublished -ceq $true -and $receipt.Status -eq 'PublishedWithErrors' -and $receipt.AppId -eq 'app-id') 'Late metadata failure lost successful publication state.'
            Assert-True ($message -match 'app-id') 'Failure did not report the existing app ID.'
            if ($scenario -ne 'FailAssignment') {
                Assert-True ($receipt.Stage -eq 'ConfiguringCategories') 'Category failure receipt lost the failing stage.'
                Assert-True (@($script:graphProbe.Calls | Where-Object Uri -match '/assignments$').Count -eq 0) 'Assignments followed a category failure.'
            }
        }
    }
    Test-Case 'Missing tenant category is rejected before creating an app' {
        $script:graphProbe = New-TestPublishProbe
        $script:graphProbe.MissingCategory = $true
        function Invoke-FactoryGraph($Method='GET',$Uri,$Body) { Invoke-TestPublishResponse $Method $Uri $Body }
        function Read-FactoryUploadArchive { @{EncryptionInfo=@{encryptionKey='fake'}} }
        function Send-FactoryEncryptedContent { }
        $tenant = [guid]::NewGuid().ToString()
        $message = Get-ExpectedError { Invoke-FactoryPublishPlan -Plan $plan -TenantId $tenant }
        Assert-True ($message -match 'Category not found') 'Category preflight did not preserve its failure.'
        Assert-True (@($script:graphProbe.Calls | Where-Object Method -ne 'GET').Count -eq 0) 'Invalid category caused a Graph mutation.'
        $receipt = Get-Content "$sandbox/upload-$tenant.json" -Raw | ConvertFrom-Json
        Assert-True ($receipt.ContentPublished -ceq $false -and $receipt.Status -eq 'Failed' -and -not $receipt.AppId) 'Preflight failure was recorded as published.'
    }
} finally {
    $checked = [IO.Path]::GetFullPath($sandbox)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $checked.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $checked -Leaf) -notmatch '^IntuneAppFactory\.GraphTests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
Write-Host "Graph tests: $script:passed passed, $script:failed failed."
if ($script:failed) { throw 'Graph tests failed.' }
