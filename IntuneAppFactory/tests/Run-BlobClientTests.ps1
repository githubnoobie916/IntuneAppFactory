#requires -Version 7.2
# Integration test: the real pinned SDK talks only to an in-process loopback server.
# Requires scripts/Install-UploadDependencies.ps1; no Azure account or SAS is used.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/IntuneUpload.ps1"
Import-FactoryBlobClient
Import-FactoryBlobClient
Write-Host 'PASS Dependency loading is repeatable in the same PowerShell session.'
$requestResult = [Microsoft.Azure.Storage.RequestResult]::new()
$requestResult.HttpStatusCode = 403
$storageFailure = [Microsoft.Azure.Storage.StorageException]::new($requestResult, 'SAS must not be echoed', [Exception]::new('inner transport failure'))
$attempts = @{Count=0}
try {
    Invoke-FactoryBlobOperation -Name 'PutBlock' -MaxRetries 2 -Operation { $attempts.Count++; throw $storageFailure }
    throw 'Expected storage failure.'
} catch {
    if ($attempts.Count -ne 1 -or $_.Exception.Message -notmatch 'HTTP 403' -or $_.Exception.Message -match 'SAS must not') { throw 'Nested permanent storage error was retried or lost its sanitized HTTP status.' }
}
Write-Host 'PASS Nested SDK storage errors preserve HTTP status and permanent failures are not retried.'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Xml;
public sealed class FactoryBlobTestServer : IDisposable {
    readonly HttpListener listener = new HttpListener();
    readonly Dictionary<string, byte[]> blocks = new Dictionary<string, byte[]>();
    readonly Task worker;
    public readonly string Uri;
    public byte[] Content = Array.Empty<byte>();
    public int BlockRequests;
    public int ListRequests;
    public int HeadRequests;
    public Exception Failure;
    public FactoryBlobTestServer() {
        var portProbe = new TcpListener(IPAddress.Loopback, 0);
        portProbe.Start(); int port = ((IPEndPoint)portProbe.LocalEndpoint).Port; portProbe.Stop();
        Uri = "http://127.0.0.1:" + port + "/";
        listener.Prefixes.Add(Uri); listener.Start();
        worker = Task.Run(() => Serve());
    }
    void Serve() {
        try {
            while (listener.IsListening) {
                var context = listener.GetContext(); var request = context.Request; var response = context.Response;
                response.Headers["x-ms-request-id"] = Guid.NewGuid().ToString();
                response.Headers["x-ms-version"] = "2019-07-07";
                response.Headers["ETag"] = "\"test-etag\"";
                response.Headers["Last-Modified"] = DateTime.UtcNow.ToString("R");
                if (request.HttpMethod == "PUT" && request.QueryString["comp"] == "block") {
                    using (var data = new MemoryStream()) {
                        request.InputStream.CopyTo(data); blocks[request.QueryString["blockid"]] = data.ToArray();
                    }
                    BlockRequests++; response.StatusCode = 201;
                } else if (request.HttpMethod == "PUT" && request.QueryString["comp"] == "blocklist") {
                    var document = new XmlDocument(); document.Load(request.InputStream);
                    using (var data = new MemoryStream()) {
                        foreach (XmlNode block in document.DocumentElement.ChildNodes) {
                            var bytes = blocks[block.InnerText]; data.Write(bytes, 0, bytes.Length);
                        }
                        Content = data.ToArray();
                    }
                    ListRequests++; response.StatusCode = 201;
                } else if (request.HttpMethod == "HEAD") {
                    HeadRequests++; response.StatusCode = 200; response.ContentLength64 = Content.Length;
                    response.Headers["x-ms-blob-type"] = "BlockBlob";
                } else { response.StatusCode = 400; }
                response.Close();
            }
        } catch (Exception error) { if (listener.IsListening) Failure = error; }
    }
    public void Dispose() { listener.Stop(); listener.Close(); worker.Wait(TimeSpan.FromSeconds(5)); }
}
'@
$server = [FactoryBlobTestServer]::new()
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('IntuneAppFactory.BlobTests-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($sandbox)
try {
    # Override only URL validation in this test's scope, constrained to this server.
    # Client creation, streams, SDK operations, size validation and retry helper are real.
    function Assert-FactoryStorageUri([string]$Uri) {
        if (-not $Uri.StartsWith($server.Uri)) { throw 'Test attempted a non-loopback storage request.' }
    }
    $path = Join-Path $sandbox 'test.intunewin'
    $expected = [byte[]]::new(1MB + 17)
    [Random]::new(42).NextBytes($expected)
    $zip = [IO.Compression.ZipFile]::Open($path, 'Create')
    try {
        $stream = $zip.CreateEntry('IntuneWinPackage/Contents/IntunePackage.intunewin').Open()
        try { $stream.Write($expected) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
    $location = @{azureStorageUri=$server.Uri + 'container/blob?sig=local-test';azureStorageUriExpirationDateTime=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
    Send-FactoryEncryptedContent -Path $path -FileUri '/unused' -Location $location -BlockSizeBytes 1MB -MaxRetries 0
    if ($server.Failure) { throw $server.Failure }
    if ($server.BlockRequests -ne 2 -or $server.ListRequests -ne 1 -or $server.HeadRequests -ne 1) { throw 'Unexpected real SDK storage requests.' }
    if ((Get-FactoryBytesHash $expected) -ne (Get-FactoryBytesHash $server.Content)) { throw 'Real SDK upload changed the payload bytes.' }
    Write-Host 'PASS Real Blob SDK uploads full and partial blocks, commits the list, and verifies blob size over loopback HTTP.'
} finally {
    $server.Dispose()
    $checked = [IO.Path]::GetFullPath($sandbox)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $checked.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $checked -Leaf) -notmatch '^IntuneAppFactory\.BlobTests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    Assert-FactoryNoLinks $checked -Recurse
    Remove-Item -LiteralPath $checked -Recurse -Force
}
