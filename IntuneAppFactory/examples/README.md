# Copy an example into apps

Copy the entire `notepadplusplus` folder from here into `apps`. Keep the app folder above its version folders:

```text
apps/
  notepadplusplus/
    README.txt
    icon.png                       # supply your PNG here; shared by all versions
    8.9.7/
      app.json
      installers/
        README.txt
        npp.8.9.7.Installer.x64.exe  # supply the approved installer
      detection/
        Detect-NotepadPlusPlus.ps1
```

The version folder, JSON, detection script and installer placeholder folder are included. The vendor installer and icon are not bundled. Add them at the locations above before building, or set `intune.icon` to `""` to omit the icon. The README in `installers` is not packaged unless you explicitly list it in `additionalFiles`.

For a different app, rename the copied app and version folders and update `app.json`: name, publisher, version (must match the version folder), architecture, installer filename and arguments, uninstall command, detection, display name, description, information URL, upload settings, and notes. Keep `"icon": "icon.png"` in every version to share the image directly under the app folder. `-AppName` is the app folder name, not necessarily the display name.

The supplied JSON uses registry detection. To use the included PowerShell example instead, replace the entire `intune.detection` object with:

```json
{
  "type": "powershell",
  "scriptPath": "detection/Detect-NotepadPlusPlus.ps1",
  "runAs32Bit": false,
  "enforceSignatureCheck": false
}
```

Adapt that script when using it for another app. It is optional when registry detection is selected.

From the `IntuneAppFactory` directory, after copying the folder:

```powershell
# Check the JSON without requiring the icon or installer.
.\scripts\Build-App.ps1 -AppName notepadplusplus -Version 8.9.7 -ValidateOnly

# After supplying the real files, build a revision.
.\scripts\Build-App.ps1 -AppName notepadplusplus -Version 8.9.7 -Revision 01
```

The generated revision is saved to `apps/notepadplusplus/8.9.7/output/rev-01/`. Review its `Package/Invoke-AppDeployToolkit.ps1` before packaging. Keep the generated `app.json` and `build.json` alongside `Package`; they preserve the revision's configuration and build metadata for upload.

For another version, copy the source configuration, installers, and detection files into a new version subfolder, excluding any generated `output/` folder. Update its JSON, installer and detection version. Keep the shared icon in the app folder. See [the upload guide](../UPLOADING.md) for packaging, preview and publication.
