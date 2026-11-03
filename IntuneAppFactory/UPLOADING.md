# Upload a generated Win32 app to Intune

`scripts/Upload-IntuneWin.ps1` adds publishing after the existing generation and packaging commands. It creates a **new** Win32 app using Microsoft Graph beta, uploads the encrypted payload from the archive, verifies publication, and optionally assigns one group.

Publishing follows the working `sources/deployapp-globalprotect.ps1` reference: Graph beta, CloudBlockBlob block uploads, blob-size verification, encrypted file commit, and content-version publication. The reference remains read-only. The factory creates one content version, provides its own dependency setup and SAS-renewal helper, and bounds waits and retries.

## PowerShell detection scripts

Replace `intune.detection` in your source `app.json` with:

```json
"detection": {
  "type": "powershell",
  "scriptPath": "detection/Detect-NotepadPlusPlus.ps1",
  "runAs32Bit": false,
  "enforceSignatureCheck": false
}
```

`scriptPath` is relative to the **application version directory**, beside `app.json`. For example, copy [Detect-NotepadPlusPlus.ps1](examples/notepadplusplus/8.9.7/detection/Detect-NotepadPlusPlus.ps1) to `apps/notepadplusplus/8.9.7/detection/Detect-NotepadPlusPlus.ps1`. This is an example based on the supplied Notepad++ configuration; confirm its registry key and minimum version against your installer.

| Setting | Meaning |
| --- | --- |
| `type` | Use `powershell` to select one custom detection script instead of the existing MSI, file or registry rule. Combine multiple checks inside the script if needed. |
| `scriptPath` | Relative `.ps1` file path. Absolute paths, traversal and symbolic links/junctions are rejected. |
| `runAs32Bit` | `false` selects the 64-bit host on 64-bit clients; `true` selects the 32-bit host. This also affects registry and filesystem redirection. |
| `enforceSignatureCheck` | `true` tells Intune to require a signature from a trusted publisher. Sign the source file before building. The factory preserves its bytes and does not validate publisher trust locally. |

Detection inherits `intune.installContext` (`system` or `user`); do not add `runAsAccount` to the detection object. The uploader uses Graph's `win32LobAppPowerShellScriptRule` with `ruleType: detection`, base64 `scriptContent`, and `notConfigured` comparison settings. You do not write base64 into your JSON. See the [Microsoft Graph script-rule reference](https://learn.microsoft.com/graph/api/resources/intune-apps-win32lobapppowershellscriptrule?view=graph-rest-1.0).

Intune reports the app as detected only when the script exits with **code 0 and writes a nonempty string to STDOUT**. A nonzero exit, no output, or STDERR output means not detected. Use `Write-Output 'Detected'` followed by `exit 0` on success, and `exit 1` otherwise. Microsoft recommends **UTF-8 with BOM**. See [Microsoft's detection rules](https://learn.microsoft.com/intune/app-management/deployment/add-win32#step-4-detection-rules).

The script must work independently on the client: do not reference factory helpers, the local source directory or files assumed to exist beside the script. Keep it compatible with the client's Windows PowerShell and test both installed and absent cases in the intended context and bitness. Building and previewing never execute it.

Build a new revision and package it as usual, then preview the upload. The builder checks UTF-8 encoding and syntax, preserves the original bytes at the revision root as `Detection/Detect.ps1`, and records its SHA256 in `build.json`. The factory imposes a 1 MiB script limit (not a claim about the Intune service limit). `-ValidateOnly` checks the JSON shape and path, without requiring or parsing the script file. Upload reads the revision copy and verifies its hash; changing the source requires a new build. Editing the saved copy directly causes upload validation to fail. The detection script is submitted separately through Graph, outside the `.intunewin` installer content. Preview JSON includes the base64 script, so keep credentials out of detection code.

## Eight upload stages

| Stage | What happens |
| --- | --- |
| 1. Validate and preview | Read the revision's `app.json`, `build.json`, and `.intunewin`; validate detection and encryption metadata; compute SHA256. |
| 2. Authenticate | Use Microsoft.Graph.Authentication, verify the requested tenant, and check delegated app-management permission. |
| 3. Create the app | Check for an existing display name, then create a Win32 app with commands, requirements, detection, exit codes, and optional PNG icon. |
| 4. Create a content version | Create the content container under the new app. |
| 5. Create the content file | Submit original/encrypted sizes and wait for Intune to issue an Azure Storage upload URL. |
| 6. Upload content | Stream the **inner encrypted payload** in configurable blocks (4 MiB by default), and commit the ordered block list. Renew the SAS URL near expiration before every attempt, including retries. Verify the committed blob length before submitting the file commit to Intune. |
| 7. Commit and verify | Submit encryption metadata from `Detection.xml`, wait for `commitFileSuccess`, set `committedContentVersion`, then wait for `published`. |
| 8. Assign optionally and record | If requested, assign one group after publication. Apply and verify configured categories, optionally assign a group, and save IDs, package hash, publication status, stage, and operation results in a local receipt. |

## Configure uploading in app.json

Edit the application's source `apps/<AppId>/<Version>/app.json` before generating a new revision. The uploader reads the **generated revision's snapshot**, so changes to source JSON do not retroactively change existing output. Use [examples/notepadplusplus/8.9.7/app.json](examples/notepadplusplus/8.9.7/app.json) as a complete, validated example adapted from the supplied script. The installer/version/switches/detection in that example are user-provided values, not a tested vendor recipe.

The script's configuration maps to the factory as follows:

| Example script variable | Factory JSON or command |
| --- | --- |
| `$appName`, `$appVersion`, `$appPublisher` | Root `name`, `version`, `publisher`. `intune.displayName` is the published title. |
| `$appDescription`, `$informationUrl` | `intune.description`, `intune.informationUrl`. |
| `$installArguments` | `install[].arguments`; installer filename goes in `install[].path`. |
| `$uninstallCommandLine` | `uninstall[]` with an EXE `executable` and `arguments`. The generated PSADT launcher remains Intune's uninstall command. |
| `$allowedArchitectures` | Root `architecture` (`x86`, `x64`, or `arm64`). |
| `$minimumSupportedOperatingSystem` | Choose `intune.upload.minimumSupportedWindowsRelease` using Graph's release notation. The example below requires Windows 11 24H2; this is **not equivalent** to the pasted script's Windows 10 1607 requirement. |
| `$registryDetectionRule` | `intune.detection`, including `operationType`, `operator`, and `check32BitOn64System`. `key` maps to Graph `keyPath`; `value` maps to `comparisonValue`. |
| `$installExperience` | `intune.installContext` and `intune.upload.restartBehavior`. |
| `$returnCodes` | `intune.upload.returnCodes`. |
| `$maxRetries`, `$blockSize`, `$sasRenewalThresholdMinutes` | `intune.upload.transport.maxRetries`, `blockSizeBytes`, `sasRenewalThresholdMinutes`. |
| `$iconPath` | `intune.icon`: PNG path relative to `apps/<AppId>/`, or `""`. Use `"icon.png"` to share the image directly under the app folder across all versions. The generator copies it into the revision. |
| `$installerUrl`, `$contentPrepUrl` | Not upload JSON: supply the approved installer locally and use the existing pinned tool setup/packaging commands. |
| `$root`, content/output/tool folders | Factory directory layout selected by `-AppName`, `-Version`, and `-Revision`, or explicit `-RevisionPath`; optional `-IntuneWinPath`. |
| Tenant/client ID, certificate or secret | Authentication command parameters or an existing SDK session. Credentials are not accepted in app JSON. |

For example, the `intune` section can be:

```json
"intune": {
  "displayName": "Notepad++ 8.9.7 (x64)",
  "description": "Notepad++ is a free source code editor and Notepad replacement.",
  "informationUrl": "https://notepad-plus-plus.org/downloads/v8.9.7/",
  "installContext": "system",
  "icon": "icon.png",
  "detection": {
    "type": "registry",
    "key": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Notepad++",
    "valueName": "DisplayVersion",
    "value": "8.9.7.0",
    "operationType": "version",
    "operator": "greaterThanOrEqual",
    "check32BitOn64System": false
  },
  "upload": {
    "deployMode": "Auto",
    "minimumSupportedWindowsRelease": "Windows11_24H2",
    "restartBehavior": "suppress",
    "returnCodes": [
      { "returnCode": 0, "type": "success" },
      { "returnCode": 3010, "type": "softReboot" },
      { "returnCode": 1641, "type": "hardReboot" },
      { "returnCode": 1618, "type": "retry" }
    ],
    "transport": {
      "maxRetries": 10,
      "blockSizeBytes": 4194304,
      "sasRenewalThresholdMinutes": 5,
      "timeoutSeconds": 900
    }
  }
}
```

This is a section of the application JSON, not a standalone complete config. JSON requires doubled backslashes in Windows paths, double quotes, numbers such as `4194304` instead of expressions such as `4 * 1024 * 1024`, and lowercase booleans. The uploader supplies Graph's `@odata.type` and `ruleType`; do not paste raw Graph rule objects into this schema.

`upload` is optional. When present, `minimumSupportedWindowsRelease` and `restartBehavior` are required. `deployMode` is optional and defaults to `Auto`. `-DeployMode`, `-MinimumSupportedWindowsRelease`, `-RestartBehavior`, and `-TimeoutSeconds` override their corresponding saved values only when explicitly supplied. For an older JSON without `upload`, supply the Windows release and restart behavior on the command line; deployment mode still defaults to `Auto`. Explicit CLI mode takes precedence over JSON, and explicit JSON mode takes precedence over the default. Preview shows the resolved app body and `Transport` settings.

`returnCodes` is optional: omitted means the existing PSADT-derived mapping; supplied means use **exactly** that nonempty list without adding other codes. Valid types are `success`, `softReboot`, `hardReboot`, `retry`, and `failed`; duplicate integer codes are rejected. These mappings describe the exit codes returned by the PSADT launcher. Keep the PSADT success/reboot behavior and Intune mappings consistent with your actual deployment.

`transport` is optional; if supplied, include all four fields:

| Field | Default when `transport` is omitted | Allowed values / meaning |
| --- | --- | --- |
| `maxRetries` | `3` | Integer 0–10. Additional Blob client attempts after the first; `10` allows 11 total attempts. Applies to block upload, block-list commit, and attribute reads; does not change Graph SDK retries. |
| `blockSizeBytes` | `4194304` | Integer 1048576–16777216 (1–16 MiB). Larger chunks use more memory. The 50,000-block limit is checked before uploading. |
| `sasRenewalThresholdMinutes` | `3` | Integer 1–30. Check before each attempt and renew when remaining SAS lifetime is below this threshold. A 403 after actual SAS expiry can retry with renewed credentials within the configured retry limit. |
| `timeoutSeconds` | `900` | Integer 1–7200 for each Intune state wait, not total transfer time. Each Blob SDK operation has a 120-second maximum execution time. |

Registry `operationType` and `operator` must be supplied together. If omitted, existing rules retain string equality. `version` and `integer` allow `equal`, `notEqual`, `greaterThan`, `greaterThanOrEqual`, `lessThan`, or `lessThanOrEqual`; `string` supports `equal`/`notEqual`. `exists`/`doesNotExist` require `operator: "notConfigured"` and `value: ""`. The value is always a JSON string, including integer comparisons. Omitting `check32BitOn64System` retains the architecture-based behavior; explicitly specifying `false` is respected.

To use the full Notepad++ example, copy it to `apps/notepadplusplus/8.9.7/app.json`, place the approved installer under that folder's `installers/`, and select an unused revision. After reviewing the generated package:

```powershell
.\scripts\Build-App.ps1 -AppName notepadplusplus -Version 8.9.7 -ValidateOnly
.\scripts\Build-App.ps1 -AppName notepadplusplus -Version 8.9.7 -Revision '01'
# Review the generated deployment before packaging.
.\scripts\New-IntuneWin.ps1 -AppName notepadplusplus -Version 8.9.7 -Revision '01'
# Optional local review, displayed as JSON in one command:
.\scripts\Upload-IntuneWin.ps1 -AppName notepadplusplus -Version 8.9.7 -Revision '01' -Preview -AsJson

# Live upload, using the same JSON settings:
.\scripts\Upload-IntuneWin.ps1 -AppName notepadplusplus -Version 8.9.7 -Revision '01' -TenantId '<tenant-guid>'
```

To avoid repeating the identifiers, use PowerShell splatting for the same workflow:

```powershell
$app = @{
    AppName = 'notepadplusplus'
    Version = '8.9.7'
    Revision = '01'
}

.\scripts\Build-App.ps1 @app
# Review the generated deployment before packaging.
.\scripts\New-IntuneWin.ps1 @app
.\scripts\Upload-IntuneWin.ps1 @app -Preview -AsJson
.\scripts\Upload-IntuneWin.ps1 @app -TenantId '<tenant-guid>'
```

These are alternative examples of the same workflow; do not run both to build or publish the same revision twice. Each successful build prints the packaging, optional JSON preview, and live upload commands with the actual app/version/revision and quoted absolute script paths. Copy those commands after reviewing the deployment; replace `<tenant-guid>` before live upload. Commands are only displayed, not executed. Validation-only runs and failed builds do not print them. Preview and upload require PowerShell 7.2 or later.

Both packaging and uploading require all three app identifiers, including an explicit `-Revision`. `-AppVersion` aliases `-Version`. Selection resolves `output/<AppName>/<Version>/rev-<Revision>` relative to the factory directory and checks its `build.json` identity. Use the exact 1-4 digit revision string: `'01'` and `'1'` identify different directories. No latest revision or source JSON default is inferred; upload settings still come from the selected revision's saved JSON.

No Notepad++ installer was downloaded or package published when adding this example. Group assignment remains an explicit command-line choice using `-GroupId` and `-AssignmentIntent`.

## One-time prerequisites

- PowerShell 7.2 or later on Windows, an active Intune tenant, and outbound access to Microsoft sign-in, Graph, and Azure Blob Storage.
- Run `./scripts/Install-UploadDependencies.ps1` in PowerShell 7. This explicitly downloads the hash-pinned Blob client and supporting assemblies from NuGet into `tools/BlobClient-11.2.3`. Publishing never installs dependencies automatically; preview requires neither these assemblies nor Graph authentication. The setup script can be rerun to repair missing or changed dependencies.
- The working reference uses **Microsoft.Azure.Storage.Blob 11.2.3**, a legacy SDK that Microsoft no longer maintains. This implementation deliberately retains that API for compatibility with the proven workflow. Versions and package/DLL hashes are recorded in `scripts/BlobClient.dependencies.json`; this is a compatibility choice, not a claim that the library is currently maintained. See the [Microsoft package notice](https://www.nuget.org/packages/Microsoft.Azure.Storage.Blob/11.2.3). SDK modernization should be validated separately against the same upload tests and a pilot tenant.
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
.\scripts\New-IntuneWin.ps1 -AppName 7zip -Version 26.05 -Revision '05'

$upload = @{
    AppName = '7zip'
    Version = '26.05'
    Revision = '05'
    DeployMode = 'Silent'
    MinimumSupportedWindowsRelease = 'Windows11_23H2'
    RestartBehavior = 'basedOnReturnCode'
}

# Local validation only; no Graph module, sign-in, receipt, or network needed.
.\scripts\Upload-IntuneWin.ps1 @upload -Preview -AsJson

# WhatIf also returns the local plan without signing in.
.\scripts\Upload-IntuneWin.ps1 @upload -WhatIf
```

Preview is optional: live upload generates and validates its own plan. `-Preview -AsJson` returns one JSON string with depth 20. For automation that needs an object, use `$plan = .\scripts\Upload-IntuneWin.ps1 @upload -Preview`; `-WhatIf` also preserves object output. `-AsJson` requires `-Preview` and cannot be used for live upload or with `-WhatIf` alone.

Existing path-based commands remain available for custom locations. Choose either app identifiers or an explicit path, not both. For example, given a generated revision saved under `D:\Packages\MyApp\rev-01` with its upload settings in JSON:

```powershell
.\scripts\New-IntuneWin.ps1 -SourcePath 'D:\Packages\MyApp\rev-01\Package' -OutputPath 'D:\Packages\MyApp\Archives'
.\scripts\Upload-IntuneWin.ps1 -RevisionPath 'D:\Packages\MyApp\rev-01' -IntuneWinPath 'D:\Packages\MyApp\Archives\Invoke-AppDeployToolkit.intunewin' -Preview -AsJson
```

Packaging overrides (`-OutputPath`, `-SetupFile`, `-ToolPath`, `-TimeoutSeconds`, `-Force`) and upload overrides, including `-IntuneWinPath`, work with either selection mode. When packaging to a custom output directory, supply the matching archive path to the uploader.

The Windows release above is an example requirement, not a recommendation for your device fleet. Choose the supported release appropriate to your organization, in Graph's notation (for example `Windows11_23H2`; Windows 10 releases use `22H2` notation). Release values are checked locally against the shared release list in AppConfig.ps1; Intune remains authoritative for service support. The release and restart behavior must be chosen either in `intune.upload` or on the command line. Deployment mode defaults to `Auto`. Interactive PSADT UI needs testing in the actual Intune execution context; use the mode appropriate to your deployment.

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

### Additional JSON options

The existing `intune` object accepts these optional properties. Unknown fields still fail validation. Credentials, app IDs and SAS URLs do not belong in application JSON.

| JSON property | Type and behavior |
| --- | --- |
| `intune.displayVersion` | Nonempty string; defaults to the root `version`. |
| `intune.developer`, `intune.owner` | Strings; explicit empty strings are accepted. |
| `intune.notes` | String; overrides the generated factory note, including when empty. Root `notes` remains local configuration commentary. |
| `intune.privacyInformationUrl` | HTTPS URL without credentials, or empty. `informationUrl` has the same rule. |
| `intune.isFeatured` | Boolean; explicit `false` is submitted. |
| `intune.allowAvailableUninstall` | Boolean; controls uninstall availability in Company Portal for available assignments. |
| `intune.categoryIds` | Array of unique category GUID strings for the target tenant. Omitted/empty means no category operations. Categories are checked before app creation, then associated through `categories/$ref` and read back after publication. |
| `intune.roleScopeTagIds` | Array of unique numeric ID strings, for example `["0", "12"]`. IDs refer to the target tenant. An explicit empty array is submitted; omission leaves the service default. |
| `intune.upload.maxRunTimeInMinutes` | Integer 1–1440; installation runtime, separate from upload waiting/transport timeouts. |
| `intune.upload.minimumFreeDiskSpaceInMB` | Integer 0–2147483647; `0` is submitted when configured. |
| `intune.upload.minimumMemoryInMB` | Integer 0–2147483647. |
| `intune.upload.minimumNumberOfProcessors` | Integer 0–2147483647. |
| `intune.upload.minimumCpuSpeedInMHz` | Integer 0–2147483647. |

Except for the display-version and existing factory-note defaults, omitted new properties are not submitted. Graph validates tenant-specific IDs and device requirement constraints. Preview exposes `ApiVersion: beta`, `CategoryIds`, and the planned `CategoryOperations` alongside the app body. The actual category operations occur only after the content is published. Group assignment is still an explicit CLI choice.

### Windows 10, Windows 11 and Auto mode

Use Graph's release strings: `"1809"` or `"22H2"` for Windows 10, and `"Windows11_24H2"` for Windows 11. Do not prefix Windows 10 values with `Windows10_`. The local allowlist currently includes Windows 10 `1607`, `1703`, `1709`, `1803`, `1809`, `1903`, `1909`, `2004`, `20H2`, `21H1`, `21H2`, `22H2`; Windows 11 `21H2`, `22H2`, `23H2`, `24H2`, `25H2`, `26H1`, `26H2` with the `Windows11_` prefix. Intune determines whether a listed release is supported by the tenant's API. Unknown values such as `Windows11_24H1` fail before sign-in. Maintain this shared allowlist when adding future releases.

Omitting `deployMode` resolves to `Auto`, including when `intune.upload` is absent and the other required settings come from the command line. Supported explicit modes are `Auto`, `Silent`, `NonInteractive` and `Interactive`. A saved `Silent` value remains `Silent`. Auto uses the supplied PSADT toolkit's native session behavior; it does not guarantee a prompt in every Intune execution context.

### GlobalProtect reference configuration

[apps/globalprotect/6.3.3-711/app.json](apps/globalprotect/6.3.3-711/app.json) is the complete example with the new options. It uses `Auto`, Windows 10 `1809`, restart behavior `allow`, a 15-minute installation runtime, 500 MB free disk space, and the reference return codes (including `1707: success` and `1602: retry`). Hardware requirements set to zero add no minimum. Architecture remains the application's explicit `x64` setting. Populate `categoryIds` and `roleScopeTagIds` for your tenant if needed; category IDs from the source script are not copied automatically.

Its application-owned detection script now reads uninstall registry registration for product `{CD809CD6-9D01-417E-9E76-D19EEE77E74F}` and exact version `6.3.3`. It avoids `Win32_Product` queries, returns code 0 with STDOUT on detection and code 1 otherwise. The reference under `sources` is unchanged. Registry registration and installer switches still require validation against your approved MSI and a pilot device.

From `IntuneAppFactory`, supply `apps/globalprotect/6.3.3-711/installers/GlobalProtect.msi`, then choose an unused revision:

```powershell
.\scripts\Install-UploadDependencies.ps1
.\scripts\Build-App.ps1 -AppName globalprotect -Version 6.3.3-711 -ValidateOnly
.\scripts\Build-App.ps1 -AppName globalprotect -Version 6.3.3-711 -Revision '02'
# Review the generated PSADT script before packaging.
.\scripts\New-IntuneWin.ps1 -AppName globalprotect -Version 6.3.3-711 -Revision '02'
.\scripts\Upload-IntuneWin.ps1 -AppName globalprotect -Version 6.3.3-711 -Revision '02' -Preview -AsJson
# Creates an unassigned app in the specified tenant:
.\scripts\Upload-IntuneWin.ps1 -AppName globalprotect -Version 6.3.3-711 -Revision '02' -TenantId '<tenant-guid>'
```

The create-new uploader will stop if the manually published app already has this display name. Review that existing app and prior receipts before retrying. A new revision is needed after changing application configuration; source edits do not alter existing revision snapshots.

| Source | Published value |
| --- | --- |
| Revision `app.json` | Publisher, architecture (`x86`, `x64`, or `arm64`), display name, description, install context. |
| `build.json` commands | Current PSADT v4 launcher commands, with the explicitly chosen `-DeployMode` appended. |
| MSI detection | Product-code presence; no invented product version. |
| File detection | File version greater than or equal to the configured version. |
| Registry detection | String equality by default, or explicit operation/operator as described above; empty `valueName` means the default value. Use full `HKEY_LOCAL_MACHINE\...` or `HKEY_CURRENT_USER\...` paths. |
| x86 detection | 32-bit file-variable expansion/registry view on 64-bit Windows; x64/arm64 use the native view. |
| PSADT success exit codes | Intune `success`. |
| PSADT reboot exit codes | `1641` maps to `hardReboot`; other configured reboot codes map to `softReboot`. |
| Other return codes | Add `1618` as `retry` and `1603` as `failed` only if not explicitly configured above. |
| `intune.upload.returnCodes` | If present, replaces the entire derived mapping above. |
| `build.json` icon | Copy's PNG bytes, if configured. PSADT UI assets are separate. |

Null detection is allowed during generation but rejected for publishing. Conflicting success/reboot codes in the derived mapping and mismatched revision metadata are rejected. The example 7-Zip detection value must be checked against the actual installed `7z.exe` file version before production assignment. Repair commands remain available in the package; this uploader configures install and uninstall in Intune.

## Receipts, duplicates, and failed uploads

The uploader writes `upload-<tenant-guid>.json` beside `build.json`, starting **before** app creation. It records IDs, category results, `ContentPublished`, sanitized failure details and the last attempted stage, but no tokens, SAS URLs, or encryption keys. A failure after verified publication records `Status: PublishedWithErrors` and keeps `ContentPublished: true`. Keep it with the package for audit and troubleshooting. `-TimeoutSeconds` (default 900) bounds each service-state wait, not the complete upload. Blob client operations use bounded retries; Microsoft Graph request handling uses the SDK. Authorization, validation, and terminal content-state failures stop the run. Sanitized Graph errors retain the method, path, HTTP status, error code, message, and request ID. Request bodies, SAS URLs, tokens, and encryption keys are excluded.

This is a create-new uploader, not an update/resume tool. An existing receipt or an app with the same display name stops publication. The archive remains locked against replacement while uploading. The local receipt prevents concurrent runs for the same revision/tenant; display names are not globally unique constraints in Graph, so coordinate uploads from different machines.

On failure:

1. Read the receipt's `Stage`, `AppId`, and content IDs. A failed category operation or assignment can leave successfully published content. `ContentPublished: true` records this separately from the later failure; finish metadata or assignments on that app rather than uploading again.
2. Inspect that app in Intune. After a lost response, an app/assignment may exist even if its ID was never received. Search by display name as well.
3. Complete assignments manually when content is already published. Do not reupload just to retry assignment.
4. If you decide to recreate an incomplete app, explicitly remove the incomplete app in Intune, preserve the receipt under a different filename, correct the cause, then rerun. Never discard a receipt before checking the tenant.

There is no automatic deletion, replacement, supersedence, rollback, or resumption. A crash while updating a receipt can leave partial JSON; inspect the tenant by display name before recovery. A forced regeneration of a revision replaces that revision's files, so preserve its upload receipts before rebuilding; prefer a new revision after publishing.

## Verification and sources

```powershell
.\tests\Run-UploadTests.ps1
.\tests\Run-GraphTests.ps1
.\tests\Run-DetectionTests.ps1
# After installing the Blob client dependencies; real SDK against localhost only:
.\tests\Run-BlobClientTests.ps1
```

Unit tests use synthetic archives and mocked Graph/storage boundaries. The Blob client integration test uses the real SDK against an in-process loopback HTTP server and verifies complete payload bytes, partial blocks, block-list commit, size verification, repeated imports, and permanent-error handling. Detection tests use mocked registry data in both PowerShell 7 and Windows PowerShell 5.1. They exercise mapping, preview, chunk boundaries, state failures, timeout behavior, publication sequencing, and receipts. A real package preview additionally validates the content-prep tool's metadata. Live upload, tenant consent/RBAC, and installation on a pilot device require a tenant validation run; they have not been verified by the local tests.

Implementation references:

- [Microsoft Graph authentication](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands)
- [Create a Win32 app](https://learn.microsoft.com/graph/api/intune-apps-win32lobapp-create?view=graph-rest-1.0)
- [Registry detection rule fields](https://learn.microsoft.com/graph/api/resources/intune-apps-win32lobappregistryrule?view=graph-rest-1.0)
- [Create content version](https://learn.microsoft.com/graph/api/intune-apps-mobileappcontent-create?view=graph-rest-1.0), [create content file](https://learn.microsoft.com/graph/api/intune-apps-mobileappcontentfile-create?view=graph-rest-1.0)
- [Azure Put Block](https://learn.microsoft.com/rest/api/storageservices/put-block), [Put Block List](https://learn.microsoft.com/rest/api/storageservices/put-block-list)
- [Commit content file](https://learn.microsoft.com/graph/api/intune-apps-mobileappcontentfile-commit?view=graph-rest-1.0)
- [Create assignment](https://learn.microsoft.com/graph/api/intune-apps-mobileappassignment-create?view=graph-rest-1.0)
