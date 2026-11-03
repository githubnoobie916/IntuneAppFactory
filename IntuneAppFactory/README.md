# IntuneAppFactory

Generate a standalone PSAppDeployToolkit 4.1.8 package from explicit application JSON, review the generated script, create an `.intunewin` file, then optionally publish it with a separate upload command.

Every generation starts with `../sources/PSAppDeployToolkit_Template_v4`. That source is read-only. Only the copied `Invoke-AppDeployToolkit.ps1` is populated; the toolkit, resources, original functions, phase markers, comments, imports, logging, and error handling are retained. The generated script contains ordinary PSADT calls and does not load factory helpers or parse JSON at deployment time.

## Workflow

Run these commands from `IntuneAppFactory` in PowerShell on Windows. Build and packaging support Windows PowerShell 5.1 and report legacy path-length limits; PowerShell 7 is recommended for long paths. Upload and preview require PowerShell 7.2 or later.

```powershell
# Validate JSON only. No output, installers, toolkit, or packaging tool required.
.\scripts\Build-App.ps1 -AppName 7zip -Version 26.05 -ValidateOnly

# Generate a new revision. Choose an unused revision to preserve earlier output.
.\scripts\Build-App.ps1 -AppName 7zip -Version 26.05 -Revision '04'

# Review/edit apps\7zip\26.05\output\rev-04\Package\Invoke-AppDeployToolkit.ps1.

# Package that exact folder separately, including your reviewed edits.
.\scripts\New-IntuneWin.ps1 -AppName 7zip -Version 26.05 -Revision '04'
```

Generation never executes an installer, downloads files, creates `.intunewin`, or publishes to Intune. Packaging does not regenerate the deployment. App-based selection resolves output relative to the factory directory, so an absolute script path also works from another working directory.

After each successful build, including a forced rebuild, Build prints ready-to-copy packaging, optional JSON preview, and live upload commands for the revision it actually generated. The commands use quoted absolute script paths, preserve leading zeros, and do not run automatically. Review the generated deployment before packaging, use PowerShell 7.2 or later for preview/upload, and replace `<tenant-guid>` with your tenant ID before live upload. `-ValidateOnly` and failed builds do not print next-step commands. Capturing the build result in a variable still returns the original object; the commands are informational output.

For the separate upload stage, see [UPLOADING.md](UPLOADING.md). `Upload-IntuneWin.ps1` accepts the same app identifiers, reads a current revision's metadata and existing archive, supports offline `-Preview` / `-WhatIf`, and uses Microsoft Graph to create and upload a new Win32 app. Use `-Preview -AsJson` to display the full plan in one command. Plain `-Preview` and `-WhatIf` return an object. Preview is optional; live upload performs its own validation. Group assignment is optional and explicit.

`Build-App.ps1 -Force` explicitly regenerates an existing recognized revision, replacing manual edits and any artifacts inside that revision, including `.intunewin` archives and upload receipts. Source configuration, installers, and other revisions remain unchanged. A failed generation preserves the previous revision. Without `-Force`, an existing revision is an error. `-Revision` overrides the JSON revision in the output snapshot without changing the source JSON.

`New-IntuneWin.ps1 -Force` replaces an existing archive only after successful packaging and verification. Use it after changing a reviewed package. The package folder remains untouched.

## Layout

```text
Intune_App_Packaging/
  sources/PSAppDeployToolkit_Template_v4/   # original toolkit; read-only
  IntuneAppFactory/
    apps/<AppId>/
      icon.png                            # optional shared icon for all versions
      <Version>/
        app.json                          # source configuration you edit
        installers/                       # approved MSI/EXE and sidecar files
        output/rev-<Revision>/
          app.json                        # effective configuration saved for this build
          build.json                      # identity, commands, Intune metadata
          Detection/Detect.ps1            # only for PowerShell detection
          icon.png                        # only when explicitly configured
          Package/
            Invoke-AppDeployToolkit.exe
            Invoke-AppDeployToolkit.ps1
            Files/                        # referenced payloads and sidecar files
            PSAppDeployToolkit/
            PSAppDeployToolkit.Extensions/
            Assets/, Config/, Strings/, SupportFiles/
          IntuneWin/                      # created only by New-IntuneWin.ps1
            Invoke-AppDeployToolkit.intunewin
            Invoke-AppDeployToolkit.stdout.log
            Invoke-AppDeployToolkit.stderr.log
    scripts/
      Build-App.ps1                       # generate a PSADT package
      AppConfig.ps1                       # build-time validation and path checks
      Update-DeploymentTemplate.ps1       # render native values and commands
      New-IntuneWin.ps1                    # separately package a reviewed folder
      IntuneWin.ps1                       # packaging checks and tool invocation
      Install-IntuneWinTool.ps1            # explicit one-time tool setup
      Upload-IntuneWin.ps1                 # preview or publish a generated revision
      IntuneUpload.ps1                     # Graph, metadata, and streaming upload helpers
      Install-UploadDependencies.ps1       # explicit hash-pinned Blob client setup
      BlobClient.ps1                       # sample-compatible Azure Blob client
      BlobClient.dependencies.json         # pinned NuGet packages and assembly hashes
    tests/
    tools/
```

Only `Package/` is deployment content. The JSON snapshots and Intune metadata stay outside it. Existing packages remain unchanged until explicitly rebuilt.

Edit `apps/<AppName>/<Version>/app.json` before building. The generated revision's `app.json` saves the effective configuration, including any `-Revision` override, so later source edits do not change that revision's upload settings. Its `build.json` records build identity, toolkit version, deployment commands, icon location, and any detection-script hash. Packaging and upload use this metadata, and forced rebuilds check it before replacing a revision. Keep both generated JSON files; neither is a deployment-time dependency.

## Application JSON

For a new application, copy the entire [examples/notepadplusplus](examples/notepadplusplus) folder into `apps`, then rename and edit it for your app. The [example setup guide](examples/README.md) shows the shared icon location, version folder, installer location and optional PowerShell detection script. Supply your own PNG and approved installer before building.

Use [apps/7zip/26.05/app.json](apps/7zip/26.05/app.json) as the basic example, or [examples/notepadplusplus/8.9.7/app.json](examples/notepadplusplus/8.9.7/app.json) for explicit upload settings. Root and PSADT fields listed below are required, even for disabled features, except where marked optional. Missing required settings and unknown properties fail validation. Conditional installer selectors and detection fields apply only to their selected type. The additional `intune.informationUrl` and `intune.upload` fields are optional for compatibility with existing applications; upload defaults and overrides are documented in [UPLOADING.md](UPLOADING.md).

The toolkit's own `Config/`, `Strings/`, and other resources are copied unchanged. This JSON controls the deployment settings exposed by the generator; it is not a replacement for every internal PSADT configuration option.

| Root field | Meaning |
| --- | --- |
| `name`, `publisher`, `version`, `architecture` | Application metadata. Architecture: `x86`, `x64`, or `arm64`. Version must match its directory. Nonempty `name` disables native zero-config MSI discovery. |
| `language`, `revision` | Explicit language and revision. Revision is a string of 1–4 digits, such as `"01"`. |
| `install`, `uninstall`, `repair` | Ordered arrays of MSI/EXE steps. Install and uninstall must be nonempty. `"repair": []` means no application repair commands; the original repair phases remain. |
| `additionalFiles` | Explicit array of sidecar paths under `installers/`; use `[]` for none. Only referenced payloads and these files are copied. |
| `psadt` | All deployment settings described below. |
| `intune` | Explicit publishing metadata described below. |
| `notes` | Maintainer text; use `""` for none. |

### Install, uninstall, and repair steps

Every step requires `type`, `arguments`, and exactly one target selector.

| Field | Meaning |
| --- | --- |
| `type` | `MSI` or `EXE`. Both can be mixed in any action's ordered array. |
| `arguments` | Literal vendor arguments. Required for every step. MSI arguments must be nonempty and include any needed UI/reboot flags. EXE `"arguments": ""` explicitly means no arguments. |
| `path` | Relative MSI/EXE path under this version's `installers/`. Required for installation; also supported for uninstall and repair. |
| `productCode` | MSI uninstall/repair only: actual nonzero product GUID in braces. Obtain it from the approved MSI. |
| `executable` | EXE uninstall/repair only: an absolute local path, or one beginning with `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramW6432%`, `%ProgramData%`, `%LocalAppData%`, `%AppData%`, or `%SystemRoot%`. Expanded on the target machine. |

Example repair steps (replace targets and arguments with verified vendor values):

```json
"repair": [
  { "type": "MSI", "path": "application.msi", "arguments": "/qn /norestart" },
  { "type": "EXE", "executable": "%ProgramFiles%\\Vendor\\Application\\setup.exe", "arguments": "/repair /quiet" }
]
```

MSI steps use `Start-ADTMsiProcess -Action Install`, `Uninstall`, or `Repair`. Repair explicitly selects native `-RepairMode Repair` (`msiexec /f`); the supplied arguments are passed alongside that action. Do not add a second `/i`, `/x`, or `/f` action to the arguments. The factory does not infer reinstall properties or vendor-specific repair switches. EXE steps use `Start-ADTProcess` with the executable's directory as their working directory. A failed step stops subsequent steps and uses the original PSADT error handling.

Strings remain data, including apostrophes, dollar signs, and text resembling template markers. JSON cannot directly select a shell interpreter. Installer arguments still require normal vendor review.

### PSADT settings

All of these fields belong in `psadt`. Only `closeProcessesCountdown` is optional.

| Field | Meaning |
| --- | --- |
| `processesToClose` | Array of objects with required `name` and `description`. Use `[]` for none. Names omit `.exe`; duplicate names are rejected without regard to case. |
| `closeProcessesCountdown` | Optional integer from 0 through 86400 seconds for all three actions when there are processes to close. Omit the field to leave `CloseProcessesCountdown` out of install, uninstall, and repair. A supplied value, including `0`, is passed unchanged; `null` is invalid. |
| `allowDefer`, `deferTimes` | Deferrals apply only to interactive installation. Uninstall and repair never defer. Keep both fields present when disabled. |
| `checkDiskSpace`, `persistPrompt` | Booleans for the original install welcome block. |
| `suppressRebootPassThru`, `terminalServerMode`, `disableLogging` | Explicit booleans mapped to native session options. |
| `scriptAuthor`, `scriptVersion`, `scriptDate` | Script metadata. Version uses dotted numeric notation; date is `yyyy-MM-dd`. |
| `successExitCodes`, `rebootExitCodes` | Nonempty arrays of 32-bit integer codes, mapped to the native session. |
| `installName`, `installTitle` | Explicit title overrides. Use `""` to let PSADT derive them. |
| `completionPrompt` | Object requiring `message`, `buttonRightText`, and `noWait`. Retains the original post-install prompt condition, `if (!$adtSession.UseDefaultMsi)`. |

```json
"processesToClose": [
  { "name": "7zFM", "description": "7-Zip File Manager" },
  { "name": "7zG", "description": "7-Zip GUI" }
]
```

Countdown and deferral counts accept integers from 0 to 86400; enabled deferrals require a positive count. Prompt `noWait` is a boolean. The message and button text must be nonempty. Toolkit dialog behavior still follows the effective deployment mode.

The generator preserves the original process condition, `if ($adtSession.AppProcessesToClose.Count -gt 0)`, for install, uninstall, and repair. Use `processesToClose: []` when no processes should be supplied. No Boolean prefixes are added to these conditions or the completion-prompt condition.

When migrating existing configurations, remove `psadt.closeProcesses` and `psadt.completionPrompt.enabled`; both are now rejected as unknown properties. Previously disabled process handling now follows the process list, and the completion-prompt call follows `UseDefaultMsi`. Existing generated packages retain their old behavior until rebuilt.

Deployment mode is supplied exclusively on the launcher command line; `psadt.deployMode` is not accepted in JSON. The generator does not supply or override it. If omitted on the command line, the original toolkit's native default handling applies. PSADT may adjust the effective mode for the target session.

For Intune publishing, `intune.upload.deployMode` can save the mode that the uploader appends to those launcher command lines. It does not change the generated script's native parameters or add a runtime JSON dependency.

Specify the desired mode when running the launcher, for example:

```text
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
Invoke-AppDeployToolkit.exe -DeploymentType Repair -DeployMode Interactive
```

Generated management command strings leave the mode unspecified so you can choose it when configuring execution. The other native switches still use their explicit JSON values unless overridden on the command line, including switches passed as `:$false`.

### Intune metadata

The required fields are `displayName`, `description`, `installContext`, `detection`, and `icon`. Optional publishing metadata includes `informationUrl`, `privacyInformationUrl`, `displayVersion`, `developer`, `owner`, `notes`, `isFeatured`, `allowAvailableUninstall`, `categoryIds`, `roleScopeTagIds`, and `upload`. See [all JSON options](UPLOADING.md#additional-json-options) and the complete [GlobalProtect configuration](apps/globalprotect/6.3.3-711/app.json).

- `installContext`: `system` or `user`. Also maps to the native `RequireAdmin` value.
- `icon`: PNG path relative to `apps/<AppId>/`, or `""` for no publishing icon. Use `"icon": "icon.png"` in each version's JSON to share `apps/<AppId>/icon.png` across versions. A configured file must exist at build time. The builder snapshots it into each revision; replacing the shared image affects future builds. PSADT UI assets remain separate.
- `detection`: `null` for no detection metadata, or an object with these required fields: MSI (`type`, `productCode`); file (`type`, `path`, `file`, `version`); registry (`type`, `key`, `valueName`, `value`); PowerShell (`type: "powershell"`, `scriptPath`, `runAs32Bit`, `enforceSignatureCheck`). The PowerShell path is relative to the application version directory; the builder snapshots the script for uploading. Registry value name/value may be empty strings. Registry rules additionally accept `operationType` and `operator` together, and optional boolean `check32BitOn64System`. See [PowerShell detection scripts](UPLOADING.md#powershell-detection-scripts) for an example, and the upload guide for registry version comparisons and supported operations.
- `informationUrl`: optional HTTPS information page URL, or `""` to omit it. This does not download an installer.
- `upload`: optional object requiring `minimumSupportedWindowsRelease` and `restartBehavior`. `deployMode` defaults to `Auto`; explicit CLI and JSON choices override it. Windows 10 (`1809`, `22H2`) and Windows 11 (`Windows11_24H2`) are supported. Optional `returnCodes` replaces the derived Intune return-code list; optional `transport` sets upload retry, chunk, SAS-renewal and wait settings. Installation runtime and hardware requirements are also configurable. See the complete [Notepad++ JSON example](examples/notepadplusplus/8.9.7/app.json) and [configuration guide](UPLOADING.md#configure-uploading-in-appjson).

This metadata is recorded for publishing. The separate uploader maps it to Intune detection rules and can optionally assign the published app to one group. The 7-Zip example's detection still needs validation against the approved installer; preview validates its shape, not its behavior on a device.

## Separate packaging

The existing local tool is used without network access. To set it up on another machine, explicitly run:

```powershell
.\scripts\Install-IntuneWinTool.ps1
```

See [tools/README.md](tools/README.md) for the pinned tool, hash, signature verification, and update procedure. Neither generation nor packaging downloads it automatically.

`New-IntuneWin.ps1` accepts either all three `-AppName`, `-Version`, and `-Revision` identifiers, or `-SourcePath`. Do not combine these selection modes. `-AppVersion` is an alias for `-Version`. App selection requires a matching generated `build.json` and packages `apps/<AppName>/<Version>/output/rev-<Revision>/Package`. Revision is an exact string of 1-4 digits: `'01'` selects `rev-01`, while `'1'` selects `rev-1`. Packaging and uploading require an explicit revision in app mode; they never choose the latest build or read a revision default from current source JSON.

Both packaging modes support `-OutputPath`, `-SetupFile`, `-ToolPath`, `-TimeoutSeconds`, and `-Force`. The default output is an `IntuneWin/` folder beside the source. Existing path-based commands remain supported, including standalone PSADT v3/v4 folders without factory metadata:

```powershell
.\scripts\New-IntuneWin.ps1 -SourcePath 'D:\Packages\MyApp\Package' -OutputPath 'D:\Packages\MyApp\IntuneWin'
```

If both v3 and v4 launchers exist, specify `-SetupFile`. Output and the packaging tool must be outside the source. Existing archives within the source, junctions/symlinks, tool failures, timeouts, and invalid resulting archives are rejected. Logs are retained beside successful archives. Packaging does not update the generation-time `build.json`.

## Migration and maintenance

New builds are stored under `apps/<AppName>/<Version>/output/rev-<Revision>`. Existing builds under `output/<AppName>/<Version>/rev-<Revision>` are not moved, deleted, or automatically selected. App-name commands use only the new layout. Both output locations are ignored by Git.

To keep using an existing build at the old location, run from `IntuneAppFactory` and specify its path. Packaging's `-SourcePath` points to `Package`; upload's `-RevisionPath` points to the revision folder containing both JSON files. Preview requires the revision's upload settings or equivalent command-line overrides as described in [UPLOADING.md](UPLOADING.md).

```powershell
# Package only if this revision does not already have an archive.
.\scripts\New-IntuneWin.ps1 -SourcePath '.\output\7zip\26.05\rev-05\Package'
.\scripts\Upload-IntuneWin.ps1 -RevisionPath '.\output\7zip\26.05\rev-05' -DeployMode Silent -MinimumSupportedWindowsRelease Windows11_23H2 -RestartBehavior basedOnReturnCode -Preview -AsJson
```

The former customized `templates/PSADT-4.1.8` tree and `AppDeployment.ps1` runtime are retired. `templateValues` is replaced by explicit JSON fields, including `psadt.scriptAuthor` and the other native metadata fields. Process strings must be expanded to objects with both name and description. Add all required settings to older JSON before rebuilding; use the complete example as the migration reference. Remove `psadt.deployMode` from older JSON and supply `-DeployMode` on the launcher command line instead. Existing generated packages retain their previous behavior until rebuilt.

`Build-App.ps1 -CreateIntuneWin` and `-IntuneWinToolPath` no longer exist. Run `New-IntuneWin.ps1` separately. Old generated revisions still contain their own runtime helpers and remain unchanged.

Generation currently targets the provided 4.1.8 template. It checks expected edit locations and parses the generated script before publication. If the upstream template changes, generation fails clearly when those locations no longer match; review the renderer and tests before adopting another release. Never modify synced files under `sources/` as part of a build.

Builds use staging, backup directories, and a revision lock inside `apps/<AppName>/<Version>/output`, preserving previous output if generation or publication fails. Packaging has its own lock and verified temporary output. An interrupted process can leave staging, backup, or lock files; confirm no build is active before manual recovery. Keep backups until recovery is complete.

## Verification

```powershell
.\tests\Run-Tests.ps1
.\tests\Run-IntuneWinTests.ps1
.\tests\Run-Tests.ps1 -WithRealTool
.\tests\Run-IntuneWinTests.ps1 -WithRealTool
# PowerShell 7.2+; mocked network, no tenant changes:
.\tests\Run-UploadTests.ps1
```

Generation tests use isolated copies and inert payloads. Generated deployment scripts are exercised with toolkit import, session, installer, process-closing, and UI boundaries mocked. Real-tool tests run Microsoft's packaging utility, never an application installer or the PSADT launcher. Tests cover configuration omissions, literal arguments, native command compatibility, detached deployment, source preservation, revision isolation, failed-build recovery, and separate packaging of reviewed edits. Real installation/uninstallation/repair behavior still requires testing approved payloads on a suitable test device.
