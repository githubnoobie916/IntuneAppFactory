# Upload a generated Win32 app to Intune

`scripts/Upload-IntuneWin.ps1` adds publishing after the existing generation and packaging commands. It creates a **new** Win32 app using Microsoft Graph v1.0, uploads the encrypted payload from the archive, verifies publication, and optionally assigns one group.

The linked Admin365 article could not be retrieved during implementation. The eight stages below describe this project's implementation based on Microsoft's documentation; they are not a verified reproduction of the article's numbered steps.

## Eight upload stages

| Stage | What happens |
| --- | --- |
| 1. Validate and preview | Read the revision's `app.json`, `build.json`, and `.intunewin`; validate detection and encryption metadata; compute SHA256. |
| 2. Authenticate | Use Microsoft.Graph.Authentication, verify the requested tenant, and check delegated app-management permission. |
| 3. Create the app | Check for an existing display name, then create a Win32 app with commands, requirements, detection, exit codes, and optional PNG icon. |
| 4. Create a content version | Create the content container under the new app. |
| 5. Create the content file | Submit original/encrypted sizes and wait for Intune to issue an Azure Storage upload URL. |
| 6. Upload content | Stream the **inner encrypted payload**, in 4 MiB blocks, and commit the ordered block list. Renew the SAS URL near expiration. |
| 7. Commit and verify | Submit encryption metadata from `Detection.xml`, wait for `commitFileSuccess`, set `committedContentVersion`, then wait for `published`. |
| 8. Assign optionally and record | If requested, assign one group after publication. Save the app/content/file IDs, package hash, stage, and assignment result in a local receipt. |

## One-time prerequisites

- PowerShell 7.2 or later on Windows, an active Intune tenant, and outbound access to Microsoft sign-in, Graph, and Azure Blob Storage.
- Install the Microsoft authentication module in PowerShell 7 if it is not already available:

  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery
  ```

- For interactive use, obtain administrator consent for the delegated `DeviceManagementApps.ReadWrite.All` permission. The signed-in operator also needs the appropriate Intune app-management RBAC permissions and scope. `-ClientId` can select your organization's registered public-client application; otherwise the SDK uses its default application. Configure a custom application's interactive/device-code authentication as described in the SDK documentation below.
- For unattended use, register an Entra application, grant **application** `DeviceManagementApps.ReadWrite.All` with admin consent, and configure a certificate. Its private key must be accessible to the account running the script. The uploader accepts a certificate thumbprint; it does not store client secrets.

This implementation targets the **Global/public cloud**. It does not configure app registrations, grant consent, install modules, or change RBAC itself. Group assignments use a supplied object ID and do not require the script to search Entra groups.

## Package and preview

Run from `IntuneAppFactory` in PowerShell 7. Choose the revision you reviewed. A current revision contains `app.json` and `build.json` alongside `Package/`.

```powershell
# Run if this revision has not yet been packaged.
.\scripts\New-IntuneWin.ps1 -SourcePath '.\output\7zip\26.05\rev-05\Package'

$upload = @{
    RevisionPath = '.\output\7zip\26.05\rev-05'
    DeployMode = 'Silent'
    MinimumSupportedWindowsRelease = 'Windows11_23H2'
    RestartBehavior = 'basedOnReturnCode'
}

# Local validation only; no Graph module, sign-in, receipt, or network needed.
$plan = .\scripts\Upload-IntuneWin.ps1 @upload -Preview
$plan | ConvertTo-Json -Depth 20

# WhatIf also returns the local plan without signing in.
.\scripts\Upload-IntuneWin.ps1 @upload -WhatIf
```

The Windows release above is an example requirement, not a recommendation for your device fleet. Choose the supported release appropriate to your organization, in Graph's notation (for example `Windows11_23H2`; Windows 10 releases use `22H2` notation). Release support is validated by Intune. `DeployMode` and `RestartBehavior` are mandatory choices. Interactive PSADT UI needs testing in the actual Intune execution context; use the mode appropriate to your deployment.

During implementation, revision 05 was packaged locally and its upload preview verified. Its archive now exists; skip the packaging command for that unchanged revision. After editing package content, explicitly repackage with `New-IntuneWin.ps1 -Force`, then preview again.

`-IntuneWinPath` can select an archive stored elsewhere. You are responsible for pairing it with the matching revision. Encryption metadata identifies the setup file and sizes, but cannot prove which application is inside. Packaging and uploading never execute the installer. Preview does not verify detection against an installed application or test tenant permissions.

Revisions created by the former factory layout (including the existing revisions 01–03) lack the current root-level snapshot and command contract. Generate a new revision with the current factory, review it, then package it. Do not combine old archives with new metadata merely to bypass validation.

## Upload without assignment

Replace placeholders with your own tenant's IDs. These commands make tenant changes; the preview above does not.

```powershell
$tenantId = '<tenant-guid>'
$result = .\scripts\Upload-IntuneWin.ps1 @upload -TenantId $tenantId
$result
```

Add `-UseDeviceCode` when your sign-in environment requires it. The script uses a process-scoped Graph connection and disconnects its own connection afterward. To use a connection you explicitly established, pass `-UseExistingConnection`; that connection is retained and must match the requested tenant and Global environment.

## Optional pilot assignment

Choose this invocation **instead of** the unassigned upload above. Both commands create an app; rerunning against the same revision/tenant is blocked by its receipt.

```powershell
# Available apps should target a user group for Company Portal.
.\scripts\Upload-IntuneWin.ps1 @upload -TenantId $tenantId `
    -GroupId '<pilot-user-group-guid>' -AssignmentIntent available

# For automatic installation, explicitly select AssignmentIntent required
# and the appropriate pilot user/device group. Do not run both examples.
```

`GroupId` and `AssignmentIntent` must be supplied together. The uploader never assigns all users or all devices. Notifications are `showAll`; no custom deadline or reboot schedule is configured. Confirm group membership in Entra before using `required`, which can initiate installation. You can also upload unassigned and configure assignments in the Intune admin center afterward.

## Unattended certificate authentication

```powershell
.\scripts\Upload-IntuneWin.ps1 @upload `
    -TenantId '<tenant-guid>' `
    -ClientId '<app-registration-client-guid>' `
    -CertificateThumbprint '<certificate-thumbprint>'
```

An automation host can establish another supported SDK connection (for example a managed identity with the required app permission) and use `-UseExistingConnection` instead. Credentials remain with the SDK/certificate store, not in application JSON.

## Metadata mapping

| Source | Published value |
| --- | --- |
| Revision `app.json` | Publisher, architecture (`x86`, `x64`, or `arm64`), display name, description, install context. |
| `build.json` commands | Current PSADT v4 launcher commands, with the explicitly chosen `-DeployMode` appended. |
| MSI detection | Product-code presence; no invented product version. |
| File detection | File version greater than or equal to the configured version. |
| Registry detection | String equality to the configured value, including an empty string; empty `valueName` means the default value. Use full `HKEY_LOCAL_MACHINE\...` or `HKEY_CURRENT_USER\...` paths. |
| x86 detection | 32-bit file-variable expansion/registry view on 64-bit Windows; x64/arm64 use the native view. |
| PSADT success exit codes | Intune `success`. |
| PSADT reboot exit codes | `1641` maps to `hardReboot`; other configured reboot codes map to `softReboot`. |
| Other return codes | Add `1618` as `retry` and `1603` as `failed` only if not explicitly configured above. |
| `build.json` icon | Copy's PNG bytes, if configured. PSADT UI assets are separate. |

Null detection is allowed during generation but rejected for publishing. Conflicting success/reboot codes and mismatched revision metadata are rejected. The example 7-Zip detection value must be checked against the actual installed `7z.exe` file version before production assignment. Repair commands remain available in the package; this uploader configures install and uninstall in Intune.

## Receipts, duplicates, and failed uploads

The uploader writes `upload-<tenant-guid>.json` beside `build.json`, starting **before** app creation. It records IDs and the last attempted stage, but no tokens, SAS URLs, or encryption keys. Keep it with the package for audit and troubleshooting. `-TimeoutSeconds` (default 900) bounds each service-state wait, not the complete upload. Storage PUTs use bounded retries; Microsoft Graph request handling uses the SDK. Authorization, validation, and terminal content-state failures stop the run.

This is a create-new uploader, not an update/resume tool. An existing receipt or an app with the same display name stops publication. The archive remains locked against replacement while uploading. The local receipt prevents concurrent runs for the same revision/tenant; display names are not globally unique constraints in Graph, so coordinate uploads from different machines.

On failure:

1. Read the receipt's `Stage`, `AppId`, and content IDs. A failed assignment can leave a successfully published, unassigned app.
2. Inspect that app in Intune. After a lost response, an app/assignment may exist even if its ID was never received. Search by display name as well.
3. Complete assignments manually when content is already published. Do not reupload just to retry assignment.
4. If you decide to recreate an incomplete app, explicitly remove the incomplete app in Intune, preserve the receipt under a different filename, correct the cause, then rerun. Never discard a receipt before checking the tenant.

There is no automatic deletion, replacement, supersedence, rollback, or resumption. A crash while updating a receipt can leave partial JSON; inspect the tenant by display name before recovery. A forced regeneration of a revision replaces that revision's files, so preserve its upload receipts before rebuilding; prefer a new revision after publishing.

## Verification and sources

```powershell
.\tests\Run-UploadTests.ps1
```

Tests use a synthetic archive and mocked Graph/storage boundaries. They exercise mapping, preview, chunk boundaries, state failures, timeout behavior, publication sequencing, and receipts. A real package preview additionally validates the content-prep tool's metadata. Live upload, tenant consent/RBAC, and installation on a pilot device require a tenant validation run; they have not been verified by the local tests.

Implementation references:

- [Microsoft Graph authentication](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands)
- [Create a Win32 app](https://learn.microsoft.com/graph/api/intune-apps-win32lobapp-create?view=graph-rest-1.0)
- [Create content version](https://learn.microsoft.com/graph/api/intune-apps-mobileappcontent-create?view=graph-rest-1.0), [create content file](https://learn.microsoft.com/graph/api/intune-apps-mobileappcontentfile-create?view=graph-rest-1.0)
- [Azure Put Block](https://learn.microsoft.com/rest/api/storageservices/put-block), [Put Block List](https://learn.microsoft.com/rest/api/storageservices/put-block-list)
- [Commit content file](https://learn.microsoft.com/graph/api/intune-apps-mobileappcontentfile-commit?view=graph-rest-1.0)
- [Create assignment](https://learn.microsoft.com/graph/api/intune-apps-mobileappassignment-create?view=graph-rest-1.0)
