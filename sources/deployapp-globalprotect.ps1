##STEP 1

$intuneWinFile = Get-ChildItem "C:\Users\tscott\Documents\Powershell Scripts\IntuneAppFactory-main\IntuneAppFactory-main\IntuneAppFactory\output\globalprotect\6.3.3-711\rev-01\IntuneWin\Invoke-AppDeployToolkit.intunewin"
$intuneWinPath = $intuneWinFile.Name
$root = "C:\Users\tscott\Documents\Powershell Scripts\IntuneAppFactory-main\IntuneAppFactory-main\IntuneAppFactory\output\globalprotect\6.3.3-711\rev-01\IntuneWin\"

##STEP 2


Add-Type -AssemblyName System.IO.Compression.FileSystem

$extractPath = Join-Path $root "Extract"
if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
New-Item -ItemType Directory -Path $extractPath -Force | Out-Null 
[System.IO.Compression.ZipFile]::ExtractToDirectory($intuneWinFile, $extractPath)

$metaXml           = [xml](Get-Content (Join-Path $extractPath "IntuneWinPackage\Metadata\Detection.xml"))
$encryptedFilePath = Get-ChildItem (Join-Path $extractPath "IntuneWinPackage\Contents") | Select-Object -First 1 -ExpandProperty FullName
$sizeEncrypted     = (Get-Item $encryptedFilePath).Length
$sizeUnencrypted   = [int64]$metaXml.ApplicationInfo.UnencryptedContentSize

$encryptionInfo = @{
    encryptionKey        = $metaXml.ApplicationInfo.EncryptionInfo.EncryptionKey
    macKey               = $metaXml.ApplicationInfo.EncryptionInfo.MacKey
    initializationVector = $metaXml.ApplicationInfo.EncryptionInfo.InitializationVector
    mac                  = $metaXml.ApplicationInfo.EncryptionInfo.Mac
    profileIdentifier    = "ProfileVersion1"
    fileDigest           = $metaXml.ApplicationInfo.EncryptionInfo.FileDigest
    fileDigestAlgorithm  = $metaXml.ApplicationInfo.EncryptionInfo.FileDigestAlgorithm
}



##STEP 3

$params = @{
	"@odata.type" = "#microsoft.graph.win32LobApp"
	"applicableArchitectures" = "none"
	"allowedArchitectures" = $null
	"allowAvailableUninstall" = $true
	"categories" = @(
		@{
			"displayName" = "Productivity"
			"id" = "ed899483-3019-425e-a470-28e901b9790e"
		}
		@{
			"displayName" = "Business"
			"id" = "2b73ae71-12c8-49be-b462-3dae769ccd9d"
		}
	)
	"description" = "VPN client. Service provided by Department of Technology."
	"developer" = "Palo Alto Networks"
	"displayName" = "GlobalProtect VPN"
	"displayVersion" = "6.3.3-711"
	"fileName" = "Invoke-AppDeployToolkit.intunewin"
	"installCommandLine" = "Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Auto"
	"installExperience" = @{
		"deviceRestartBehavior" = "allow"
		"maxRunTimeInMinutes" = 15
		"runAsAccount" = "system"
	}
	"informationUrl" = "https://docs.paloaltonetworks.com/globalprotect/getting-started/globalprotect-overview"
      "largeIcon" = @{
        "@odata.type" = "#microsoft.graph.mimeContent"
        "type"        = "image/png"
        "value"       = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\Users\tscott\Documents\Powershell Scripts\IntuneAppFactory-main\IntuneAppFactory-main\IntuneAppFactory\output\globalprotect\6.3.3-711\rev-01\icon.png"))
    }
	"isFeatured" = $false
	"roleScopeTagIds" = @()
	"notes" = ""
	"minimumFreeDiskSpaceInMB" = 500
	"minimumSupportedWindowsRelease" = "1809"
	"msiInformation" = $null
	"owner" = ""
	"privacyInformationUrl" = ""
	"publisher" = "Palo Alto Networks"
	"returnCodes" = @(
		@{
			"returnCode" = 0
			"type" = "success"
		}
		@{
			"returnCode" = 1707
			"type" = "success"
		}
		@{
			"returnCode" = 3010
			"type" = "softReboot"
		}
		@{
			"returnCode" = 1641
			"type" = "hardReboot"
		}
		@{
			"returnCode" = 1618
			"type" = "retry"
		}
		@{
			"returnCode" = 60001
			"type" = "failed"
		}
		@{
			"returnCode" = 60008
			"type" = "failed"
		}
		@{
			"returnCode" = 60010
			"type" = "failed"
		}
		@{
			"returnCode" = 60011
			"type" = "failed"
		}
		@{
			"returnCode" = 1602
			"type" = "retry"
		}
	)
	"rules" = @(
		@{
			"@odata.type" = "#microsoft.graph.win32LobAppPowerShellScriptRule"
			"ruleType" = "detection"
			"scriptContent" = "77u/IyNuZGFkb2JlIG1zaSBpbnN0YWxsIEdVSUQgaXMgZGlmZmVyZW50IGRlcGVuZGluZyBpZiBNU0kgb3IgRVhFIGlzIHVzZWQsIGV2ZW4gd2hlbiB0aGUgdmVyc2lvbiBudW1iZXIgaXMgdGhlIHNhbWUuCgokZ2xvYmFscHJvdGVjdGFwcCA9IEdldC1XbWlPYmplY3QgV2luMzJfUHJvZHVjdCB8IApXaGVyZS1PYmplY3QgewogICAgJF8uTmFtZSAtbWF0Y2ggJ0dsb2JhbHByb3RlY3QnIC1hbmQgCiAgICAkXy5WZXJzaW9uIC1lcSAnNi4zLjMnIC1hbmQKICAgICRfLklkZW50aWZ5aW5nTnVtYmVyIC1lcSB7Q0Q4MDlDRDYtOUQwMS00MTdFLTlFNzYtRDE5RUVFNzdFNzRGfQp9CgppZiAoJGdsb2JhbHByb3RlY3RhcHApewogICAgd3JpdGUtaG9zdCAiR2xvYmFscHJvdGVjdCBpcyBpbnN0YWxsZWQiCiAgICBleGl0IDAKfQplbHNlIHsKICAgIHdyaXRlLWhvc3QgIkdsb2JhbHByb3RlY3Qgd2FzIG5vdCBkZXRlY3RlZCIKICAgIGV4aXQgMQp9"
			"enforceSignatureCheck" = $false
			"operationType" = "notConfigured"
			"operator" = "notConfigured"
		}
	)
	"runAs32Bit" = $false
	"setupFilePath" = "Invoke-AppDeployToolkit.exe"
	"uninstallCommandLine" = " Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Auto"
	"activeInstallScript" = $null
	"activeUninstallScript" = $null
}

$app = Invoke-MgGraphRequest `
-Method POST `
-Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/" `
-Body ($params | ConvertTo-Json -Depth 10) `
-ContentType "application/json"

$appId = $app.id


#step 4


$contentVersion   = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
    -Body "{}" -ContentType "application/json"
$contentVersionId = $contentVersion.id

$fileBody = [ordered]@{
    "@odata.type" = "#microsoft.graph.mobileAppContentFile"
    name          = $metaXml.ApplicationInfo.FileName
    size          = $sizeUnencrypted
    sizeEncrypted = $sizeEncrypted
    isDependency  = $false
    manifest      = $null
} | ConvertTo-Json -Compress

$contentVersion   = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
    -Body "{}" -ContentType "application/json"
$contentVersionId = $contentVersion.id

$fileBody = [ordered]@{
    "@odata.type" = "#microsoft.graph.mobileAppContentFile"
    name          = $metaXml.ApplicationInfo.FileName
    size          = $sizeUnencrypted
    sizeEncrypted = $sizeEncrypted
    isDependency  = $false
    manifest      = $null
} | ConvertTo-Json -Compress

$fileEntry = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$contentVersionId/files" `
    -Body $fileBody -ContentType "application/json"

$fileId  = $fileEntry.id
$fileUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$contentVersionId/files/$fileId"



#step5


do {
    Start-Sleep -Seconds 3
    $fileStatus = Invoke-MgGraphRequest -Method GET -Uri $fileUri
} until ($fileStatus.uploadState -eq 'azureStorageUriRequestSuccess')

$azureStorageUri = $fileStatus.azureStorageUri
$sasExpiry       = ([datetime]$fileStatus.azureStorageUriExpirationDateTime).ToUniversalTime()


#next step

function New-IntuneBlobClient {
    param([Parameter(Mandatory)][string]$AzureStorageUri)
    $qIndex      = $AzureStorageUri.IndexOf('?')
    $blobBaseUri = $AzureStorageUri.Substring(0, $qIndex)
    $sasToken    = $AzureStorageUri.Substring($qIndex + 1)
    $credentials = [Microsoft.Azure.Storage.Auth.StorageCredentials]::new($sasToken)
    return [Microsoft.Azure.Storage.Blob.CloudBlockBlob]::new([System.Uri]::new($blobBaseUri), $credentials)
}




#next step
$blockSize  = 4 * 1024 * 1024
$fileStream = [System.IO.File]::OpenRead($encryptedFilePath)
$buffer     = New-Object byte[] $blockSize
$blockIds   = [System.Collections.Generic.List[string]]::new()
$blobClient = New-IntuneBlobClient -AzureStorageUri $azureStorageUri

try {
    while (($bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {

        $blockId = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($blockIds.Count.ToString("D8"))
        )
        $blockIds.Add($blockId)

        $memStream = [System.IO.MemoryStream]::new()
        $memStream.Write($buffer, 0, $bytesRead)
        $memStream.Position = 0

        # Proactive SAS renewal
        if ((Get-Date).ToUniversalTime().AddMinutes(5) -ge $sasExpiry) {
            $status          = Invoke-IntuneSasRenewal -FileUri $fileUri
            $azureStorageUri = $status.azureStorageUri
            $sasExpiry       = ([datetime]$status.azureStorageUriExpirationDateTime).ToUniversalTime()
            $blobClient      = New-IntuneBlobClient -AzureStorageUri $azureStorageUri
        }

        # Block upload with retry
        $blockUploaded = $false
        $attempt       = 0
        do {
            try {
                $memStream.Position = 0
                $blobClient.PutBlock($blockId, $memStream, $null)
                $blockUploaded = $true
            }
            catch {
                if (++$attempt -ge 4) { throw }
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
            }
        } until ($blockUploaded)

        $memStream.Dispose()
    }
    $blobClient.PutBlockList($blockIds)
}
finally {
    $fileStream.Dispose()
}


#checking

$blobClient.FetchAttributes()

[pscustomobject]@{
    ExpectedEncryptedSize = $sizeEncrypted
    UploadedBlobSize      = $blobClient.Properties.Length
    SizeMatches           = ($blobClient.Properties.Length -eq $sizeEncrypted)
}


#Step 7 - commit the content

$commitBody = @{ fileEncryptionInfo = $encryptionInfo } | ConvertTo-Json -Depth 5 -Compress
Invoke-MgGraphRequest -Method POST -Uri "$fileUri/commit" -Body $commitBody -ContentType "application/json"

do {
    Start-Sleep -Seconds 5
    $fileStatus = Invoke-MgGraphRequest -Method GET -Uri $fileUri
    if ($fileStatus.uploadState -eq 'commitFileFailed') { throw "Commit failed" }
} until ($fileStatus.uploadState -eq 'commitFileSuccess')


#step8 Point the App at Its Content Version
$patchBody = @{
    "@odata.type"           = "#microsoft.graph.win32LobApp"
    committedContentVersion = $contentVersionId
} | ConvertTo-Json -Compress

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId" `
    -Body $patchBody `
    -ContentType "application/json"


#step8 Verify

$appStatus = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId"

$appStatus | Select-Object displayName, committedContentVersion, publishingState