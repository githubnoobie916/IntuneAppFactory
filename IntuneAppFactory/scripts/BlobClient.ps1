#requires -Version 7.2
# Matches the proven sample's CloudBlockBlob API. No downloads during publishing.
function Get-FactoryBlobDependencies {
    Get-Content -LiteralPath "$PSScriptRoot/BlobClient.dependencies.json" -Raw | ConvertFrom-Json
}

function Import-FactoryBlobClient {
    $directory = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/BlobClient-11.2.3'
    Assert-FactoryNoLinks $directory -Recurse
    foreach ($package in Get-FactoryBlobDependencies) {
        $path = Join-Path $directory "$($package.id).dll"
        if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $package.dllSha256) {
            throw 'Blob client dependency missing or changed. Run scripts/Install-UploadDependencies.ps1 in PowerShell 7 before publishing.'
        }
    }
    foreach ($package in Get-FactoryBlobDependencies) {
        $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $package.id } | Select-Object -First 1
        if ($loaded) {
            $version = $loaded.GetName().Version
            # PowerShell ships Newtonsoft.Json 13; reuse it to avoid assembly conflicts.
            $expectedVersion = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $directory "$($package.id).dll")).Version
            $compatible = if ($package.id -eq 'Newtonsoft.Json') { $version.Major -eq 13 } else { $version -eq $expectedVersion }
            if (-not $compatible) { throw "Conflicting $($package.id) assembly version $version. Start a fresh PowerShell 7 session." }
        } else {
            Add-Type -Path (Join-Path $directory "$($package.id).dll") -ErrorAction Stop
        }
    }
}

function New-FactoryBlobClient([string]$Uri) {
    Assert-FactoryStorageUri $Uri
    $index = $Uri.IndexOf('?')
    $credentials = [Microsoft.Azure.Storage.Auth.StorageCredentials]::new($Uri.Substring($index + 1))
    $client = [Microsoft.Azure.Storage.Blob.CloudBlockBlob]::new([uri]$Uri.Substring(0, $index), $credentials)
    # The factory owns retries so JSON maxRetries has one unambiguous meaning.
    $client.ServiceClient.DefaultRequestOptions.RetryPolicy = [Microsoft.Azure.Storage.RetryPolicies.NoRetry]::new()
    $client.ServiceClient.DefaultRequestOptions.MaximumExecutionTime = [TimeSpan]::FromSeconds(120)
    $client.ServiceClient.DefaultRequestOptions.ServerTimeout = [TimeSpan]::FromSeconds(120)
    return $client
}

function Invoke-FactoryBlobOperation {
    param([scriptblock]$Operation, [ValidateRange(0,10)][int]$MaxRetries, [string]$Name)
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try { return (& $Operation) }
        catch {
            $exception = $_.Exception
            while ($exception.InnerException) { $exception = $exception.InnerException }
            $status = $exception.RequestInformation.HttpStatusCode
            if ($status -and [int]$status -notin @(408,429,500,502,503,504)) {
                throw "Azure Blob $Name failed (HTTP $status); SAS details omitted."
            }
            if ($attempt -ge $MaxRetries) { throw "Azure Blob $Name failed after $($MaxRetries + 1) attempts (HTTP $status); SAS details omitted." }
            Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt + 1)))
        }
    }
}
