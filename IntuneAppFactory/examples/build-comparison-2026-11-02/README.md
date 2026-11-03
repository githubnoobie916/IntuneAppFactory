# PSADT build examples and source comparison

Both examples were built successfully on November 2, 2026 using generator commit `c7b9fa3` and the repository's PSADT 4.1.8 template. All three process conditions and the completion-prompt condition remain exactly as written in the source template. Neither generated script contains an added `$false -and` or `$true -and` condition.

| Saved example | Installer | Detection | Full local build |
| --- | --- | --- | --- |
| [7-Zip 26.05 revision 06](msi-file-detection/Invoke-AppDeployToolkit.ps1) | MSI, existing local `7z2605-x64.msi` | File version: `%ProgramFiles%\7-Zip\7z.exe`, minimum `26.05` | [Package](../../output/7zip/26.05/rev-06/Package) |
| [Notepad++ 8.9.7 revision 01](exe-script-detection/Invoke-AppDeployToolkit.ps1) | EXE, `npp.8.9.7.Installer.x64.exe` | PowerShell: 64-bit uninstall registry `DisplayVersion`, minimum `8.9.7` | [Package](../../output/notepadplusplus/8.9.7/rev-01/Package) |

The full builds include the toolkit and real installer payloads and are saved locally under `output/`. This comparison folder preserves the source entry script, generated entry scripts, configuration and build metadata snapshots, the EXE detection script, exact diffs, and [validation results](validation.json). The script snapshots in this folder are review copies; use the full `Package` folders for deployment testing. Vendor installers and full build output are excluded from Git by the existing repository rules.

## Differences from the source script

See the complete [MSI diff](msi-file-detection/source-vs-generated.diff) and [EXE diff](exe-script-detection/source-vs-generated.diff), both compared with the saved [source script](source/Invoke-AppDeployToolkit.ps1). The following table accounts for every changed section. Line references are for the generated scripts.

| Area | MSI example | EXE example |
| --- | --- | --- |
| Application metadata, lines 91–102 | Vendor `Igor Pavlov`, name `7-Zip`, version `26.05`, architecture `x64`, revision `06`; process list contains `7zFM` / `7-Zip File Manager` | Vendor `Notepad++ Team`, name `Notepad++`, version `8.9.7`, architecture `x64`; revision remains `01` and process list remains empty |
| Script metadata, lines 101–102 | Date changes from `2026-01-14` to configured `2026-11-01`; author changes to `IntuneAppFactory` | Same changes; the script date is copied from configuration, not replaced with the build date |
| Welcome options, line 129 | `AllowDefer` changes from `$true` to configured `$false` | Same |
| Install countdown, line 138 | Adds `$saiwParams.Add('CloseProcessesCountdown', 60)` inside the original process condition | Same generated statement; the empty process list means this block is skipped |
| Install tasks, lines 169–170 | Resolves the bundled MSI path and adds `Start-ADTMsiProcess -Action Install` with `/qn /norestart REBOOT=ReallySuppress` | Resolves the bundled EXE path and adds `Start-ADTProcess` with `/S` and the installer's parent folder as working directory |
| Completion prompt, line 184 | Replaces generic text with `7-Zip installation completed.`; renders `-NoWait` as equivalent `-NoWait:$true` | Uses `Notepad++ installation completed.` and the same explicit `NoWait` value |
| Uninstall tasks, MSI lines 229–230 / EXE lines 229–231 | Resolves the bundled MSI and calls `Start-ADTMsiProcess -Action Uninstall` with `/qn /norestart REBOOT=ReallySuppress` | Expands `%ProgramFiles%\Notepad++\uninstall.exe`, checks that it is an absolute path without unresolved environment variables, then invokes it with `/S` |
| Session defaults, MSI lines 318–320 / EXE lines 319–321 | Adds `$false` defaults for `SuppressRebootPassThru`, `TerminalServerMode`, and `DisableLogging` only when the corresponding command-line parameter was not supplied | Same |

The three remaining `$false` session defaults are configuration values assigned to parameters. They are not Boolean prefixes added to the process or completion conditions. Explicit launcher arguments still override them.

## Conditions and template content preserved

| Condition | Source line | MSI line | EXE line |
| --- | --- | --- | --- |
| Install: `if ($adtSession.AppProcessesToClose.Count -gt 0)` | 135 | 135 | 135 |
| Completion: `if (!$adtSession.UseDefaultMsi)` | 179 | 182 | 182 |
| Uninstall: `if ($adtSession.AppProcessesToClose.Count -gt 0)` | 198 | 201 | 201 |
| Repair: `if ($adtSession.AppProcessesToClose.Count -gt 0)` | 249 | 254 | 255 |

The launcher parameter block, all template comments, deployment phases, zero-config MSI blocks, module loading, and error handling remain unchanged. The source's four-hour `DeferRunInterval` remains unchanged at line 133. Uninstall and repair retain their existing 60-second countdown arguments. Neither configuration defines repair tasks, so no custom repair installer command is added.

Both examples populate `AppName`, which disables the template's zero-config MSI mode. The completion-prompt condition therefore permits the prompt call for these configured installations, including the MSI example. Actual display behavior is still controlled by PSADT's effective deployment mode.

## Detection is separate from the deployment script

The detection-method choice adds no detection code to `Invoke-AppDeployToolkit.ps1`.

- The MSI example stores its file-version detection settings in [app.json](msi-file-detection/app.json) and [build.json](msi-file-detection/build.json). The uploader maps this to a file-version rule using `greaterThanOrEqual` and the configured version `26.05`.
- The EXE example stores PowerShell detection settings in [app.json](exe-script-detection/app.json). The builder saves a byte-identical [Detection/Detect.ps1](exe-script-detection/Detection/Detect.ps1) alongside `Package`, and records its path and SHA-256 in [build.json](exe-script-detection/build.json). It is not placed inside the installer package. The script checks `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++`, outputs a detection message and exits `0` for version `8.9.7` or later, and exits `1` otherwise. Its Intune settings specify `runAs32Bit: false` and `enforceSignatureCheck: false`.

## Verification and scope

Both generated scripts parse successfully. Each preserves the four original conditions, launcher parameters, and source comments. All 221 other template files in each package are byte-identical to the source, and each packaged installer matches its input SHA-256. The repository source template remains unchanged.

The existing deployment probe exercised Install, Uninstall, and Repair for both packages with installer, process-closing, and UI calls mocked. All six runs returned exit code `0`. Install and Uninstall each issued one mocked installer call; Repair issued none. The 7-Zip process list was passed to the welcome dialog for all three actions. The Notepad++ empty process list left the install welcome dialog without process-closing arguments and skipped the uninstall/repair welcome dialogs. Both installations issued one mocked completion-prompt call.

This verifies generation and command flow; neither installer was executed, applications were not installed, and detection was not tested against a newly installed application. No `.intunewin` was created and nothing was uploaded to Intune.

The Notepad++ EXE was downloaded from its [official 8.9.7 release](https://github.com/notepad-plus-plus/notepad-plus-plus/releases/tag/v8.9.7), and its SHA-256 matched the release's published value:

```text
1884e093bae261c4942210334e1f2eae71354913e4ded3cc1a4a18c5320741ec
```

The MSI was already present locally. All input and output hashes are saved in `validation.json`.

Citrix was not used for this comparison: its EXE was unavailable locally, and its current detection script checks Notepad++ instead of Citrix Workspace. Those existing Citrix inputs were not changed.

## Reproduce the builds

Run from the repository root with PowerShell 7. The commands below produced the saved builds:

```powershell
pwsh -NoProfile -File IntuneAppFactory/scripts/Build-App.ps1 -AppName 7zip -Version 26.05 -Revision 06
pwsh -NoProfile -File IntuneAppFactory/scripts/Build-App.ps1 -AppName notepadplusplus -Version 8.9.7 -Revision 01
```

These revisions now exist. Choose unused revision numbers for another build, or explicitly use `-Force` if you intend to replace an existing generated revision. Supply the respective vendor installers under each app version's `installers/` directory on another checkout. The 7-Zip input also requires its configured `apps/7zip/icon.png`. The new Notepad++ input uses no icon and keeps the existing example's `/S` install and uninstall switches.
