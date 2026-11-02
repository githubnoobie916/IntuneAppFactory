# IntuneAppFactory

Generate a standalone PSAppDeployToolkit 4.1.8 package from explicit application JSON, review the generated script, create an `.intunewin` file, then optionally publish it with a separate upload command.

Every generation starts with `../sources/PSAppDeployToolkit_Template_v4`. That source is read-only. Only the copied `Invoke-AppDeployToolkit.ps1` is populated; the toolkit, resources, original functions, phase markers, comments, imports, logging, and error handling are retained. The generated script contains ordinary PSADT calls and does not load factory helpers or parse JSON at deployment time.

## Workflow

Run these commands from `IntuneAppFactory` in PowerShell on Windows. PowerShell 7 is recommended for long paths; the scripts also support Windows PowerShell 5.1 and report legacy path-length limits.

```powershell
# Validate JSON only. No output, installers, toolkit, or packaging tool required.
.\scripts\Build-App.ps1 -AppName 7zip -Version 26.05 -ValidateOnly

# Generate a new revision. Choose an unused revision to preserve earlier output.
.\scripts\Build-App.ps1 -AppName 7zip -Version 26.05 -Revision 04

# Review/edit output\7zip\26.05\rev-04\Package\Invoke-AppDeployToolkit.ps1.

# Package that exact folder separately, including your reviewed edits.
.\scripts\New-IntuneWin.ps1 -SourcePath '.\output\7zip\26.05\rev-04\Package'
```

Generation never executes an installer, downloads files, creates `.intunewin`, or publishes to Intune. Packaging does not regenerate the deployment. An absolute path to either script also works from another working directory.

For the separate upload stage, see [UPLOADING.md](UPLOADING.md). `Upload-IntuneWin.ps1` reads a current revision's metadata and existing archive, supports offline `-Preview` / `-WhatIf`, and uses Microsoft Graph to create and upload a new Win32 app. Group assignment is optional and explicit. Uploading requires PowerShell 7.2 or later; existing generation and packaging retain their Windows PowerShell 5.1 support.

`Build-App.ps1 -Force` explicitly regenerates an existing recognized revision, replacing manual edits and any artifacts inside that revision. A failed generation preserves the previous revision. Without `-Force`, an existing revision is an error. `-Revision` overrides the JSON revision in the output snapshot without changing the source JSON.

`New-IntuneWin.ps1 -Force` replaces an existing archive only after successful packaging and verification. Use it after changing a reviewed package. The package folder remains untouched.

## Layout

```text
Intune_App_Packaging/
  sources/PSAppDeployToolkit_Template_v4/   # original toolkit; read-only
  IntuneAppFactory/
    apps/<AppId>/<Version>/
      app.json
      installers/                         # approved MSI/EXE and sidecar files
    scripts/
      Build-App.ps1                       # generate a PSADT package
      AppConfig.ps1                       # build-time validation and path checks
      Update-DeploymentTemplate.ps1       # render native values and commands
      New-IntuneWin.ps1                    # separately package a reviewed folder
      IntuneWin.ps1                       # packaging checks and tool invocation
      Install-IntuneWinTool.ps1            # explicit one-time tool setup
      Upload-IntuneWin.ps1                 # preview or publish a generated revision
      IntuneUpload.ps1                     # Graph, metadata, and streaming upload helpers
    tests/
    tools/
    output/<AppId>/<Version>/rev-<Revision>/
      app.json                            # effective build inputs; not a runtime dependency
      build.json                          # identity, commands, Intune metadata
      icon.png                            # only when explicitly configured
      Package/
        Invoke-AppDeployToolkit.exe
        Invoke-AppDeployToolkit.ps1
        Files/                            # referenced install/uninstall/repair payloads + sidecars
        PSAppDeployToolkit/
        PSAppDeployToolkit.Extensions/
        Assets/, Config/, Strings/, SupportFiles/
      IntuneWin/                          # created only by New-IntuneWin.ps1
        Invoke-AppDeployToolkit.intunewin
        Invoke-AppDeployToolkit.stdout.log
        Invoke-AppDeployToolkit.stderr.log
```

Only `Package/` is deployment content. The JSON snapshots and Intune metadata stay outside it. Existing packages remain unchanged until explicitly rebuilt.

## Application JSON

Use [apps/7zip/26.05/app.json](apps/7zip/26.05/app.json) as the complete example. Every field listed below is required, even for disabled features. Missing settings and unknown properties fail validation; the factory supplies no silent deployment defaults. Conditional installer selectors and detection fields are the exceptions: include only the fields applicable to the selected type.

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

All of these fields belong in `psadt` and must be present.

| Field | Meaning |
| --- | --- |
| `processesToClose` | Array of objects with required `name` and `description`. Use `[]` for none. Names omit `.exe`; duplicate names are rejected without regard to case. |
| `closeProcesses` | Boolean controlling whether configured processes are passed to the welcome dialog for install, uninstall, and repair. |
| `closeProcessesCountdown` | Explicit countdown in seconds for all three actions when process closing is enabled. |
| `allowDefer`, `deferTimes` | Deferrals apply only to interactive installation. Uninstall and repair never defer. Keep both fields present when disabled. |
| `checkDiskSpace`, `persistPrompt` | Booleans for the original install welcome block. |
| `suppressRebootPassThru`, `terminalServerMode`, `disableLogging` | Explicit booleans mapped to native session options. |
| `scriptAuthor`, `scriptVersion`, `scriptDate` | Script metadata. Version uses dotted numeric notation; date is `yyyy-MM-dd`. |
| `successExitCodes`, `rebootExitCodes` | Nonempty arrays of 32-bit integer codes, mapped to the native session. |
| `installName`, `installTitle` | Explicit title overrides. Use `""` to let PSADT derive them. |
| `completionPrompt` | Object requiring `enabled`, `message`, `buttonRightText`, and `noWait`. Retains the original post-install prompt section. |

```json
"processesToClose": [
  { "name": "7zFM", "description": "7-Zip File Manager" },
  { "name": "7zG", "description": "7-Zip GUI" }
]
```

Countdown and deferral counts accept integers from 0 to 86400; enabled deferrals require a positive count. Prompt `enabled` and `noWait` are booleans. The message may be empty only when disabled; the button text must be nonempty. Toolkit dialog behavior still follows the effective deployment mode.

Deployment mode is supplied exclusively on the launcher command line; `psadt.deployMode` is not accepted in JSON. The generator does not supply or override it. If omitted on the command line, the original toolkit's native default handling applies. PSADT may adjust the effective mode for the target session.

Specify the desired mode when running the launcher, for example:

```text
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
Invoke-AppDeployToolkit.exe -DeploymentType Repair -DeployMode Interactive
```

Generated management command strings leave the mode unspecified so you can choose it when configuring execution. The other native switches still use their explicit JSON values unless overridden on the command line, including switches passed as `:$false`.

### Intune metadata

All fields must be present: `displayName`, `description`, `installContext`, `detection`, and `icon`.

- `installContext`: `system` or `user`. Also maps to the native `RequireAdmin` value.
- `icon`: PNG path relative to `apps/<AppId>/`, or `""` for no publishing icon. A configured file must exist at build time. PSADT UI assets remain separate.
- `detection`: `null` for no detection metadata, or an object with one of these exact field sets: MSI (`type`, `productCode`); file (`type`, `path`, `file`, `version`); registry (`type`, `key`, `valueName`, `value`). Registry value name/value may be empty strings.

This metadata is recorded for publishing. The separate uploader maps it to Intune detection rules and can optionally assign the published app to one group. The 7-Zip example's detection still needs validation against the approved installer; preview validates its shape, not its behavior on a device.

## Separate packaging

The existing local tool is used without network access. To set it up on another machine, explicitly run:

```powershell
.\scripts\Install-IntuneWinTool.ps1
```

See [tools/README.md](tools/README.md) for the pinned tool, hash, signature verification, and update procedure. Neither generation nor packaging downloads it automatically.

`New-IntuneWin.ps1` accepts `-SourcePath`, `-OutputPath`, `-SetupFile`, `-ToolPath`, `-TimeoutSeconds`, and `-Force`. Its default output is an `IntuneWin/` folder beside the source. It supports root PSADT v4 and v3 launchers; if both exist, specify `-SetupFile`. Output and the packaging tool must be outside the source. Existing archives within the source, junctions/symlinks, tool failures, timeouts, and invalid resulting archives are rejected. Logs are retained beside successful archives. Packaging does not update the generation-time `build.json`.

## Migration and maintenance

The former customized `templates/PSADT-4.1.8` tree and `AppDeployment.ps1` runtime are retired. `templateValues` is replaced by explicit JSON fields, including `psadt.scriptAuthor` and the other native metadata fields. Process strings must be expanded to objects with both name and description. Add all required settings to older JSON before rebuilding; use the complete example as the migration reference. Remove `psadt.deployMode` from older JSON and supply `-DeployMode` on the launcher command line instead. Existing generated packages retain their previous behavior until rebuilt.

`Build-App.ps1 -CreateIntuneWin` and `-IntuneWinToolPath` no longer exist. Run `New-IntuneWin.ps1` separately. Old generated revisions still contain their own runtime helpers and remain unchanged.

Generation currently targets the provided 4.1.8 template. It checks expected edit locations and parses the generated script before publication. If the upstream template changes, generation fails clearly when those locations no longer match; review the renderer and tests before adopting another release. Never modify synced files under `sources/` as part of a build.

Builds use staging and a revision lock, preserving previous output if generation or publication fails. Packaging has its own lock and verified temporary output. An interrupted process can leave staging, backup, or lock files; confirm no build is active before manual recovery. Keep backups until recovery is complete.

## Verification

```powershell
.\tests\Run-Tests.ps1
.\tests\Run-Tests.ps1 -WithRealTool
.\tests\Run-IntuneWinTests.ps1 -WithRealTool
# PowerShell 7.2+; mocked network, no tenant changes:
.\tests\Run-UploadTests.ps1
```

Generation tests use isolated copies and inert payloads. Generated deployment scripts are exercised with toolkit import, session, installer, process-closing, and UI boundaries mocked. Real-tool tests run Microsoft's packaging utility, never an application installer or the PSADT launcher. Tests cover configuration omissions, literal arguments, native command compatibility, detached deployment, source preservation, revision isolation, failed-build recovery, and separate packaging of reviewed edits. Real installation/uninstallation/repair behavior still requires testing approved payloads on a suitable test device.
