GlobalProtect VPN 6.3.3-711

Place the approved GlobalProtect.msi in 6.3.3-711/installers/.
No vendor installer is bundled or downloaded. GlobalProtect-icon.png is shared
at this application root and copied into each generated revision.

app.json uses Auto, Windows 10 1809, restart behavior allow, a 15-minute
installation timeout and 500 MB minimum free disk space, following the working
reference. Edit these choices for your deployment before building a new revision.
The optional metadata fields are demonstrated in this JSON; categoryIds and
roleScopeTagIds need your own tenant's IDs. Empty categoryIds means no categories.

Detection reads uninstall registration for product
{CD809CD6-9D01-417E-9E76-D19EEE77E74F} and exact version 6.3.3. Verify those values
against the approved MSI and pilot device. It does not query Win32_Product.

Run scripts/Install-UploadDependencies.ps1 once in PowerShell 7 before live
publishing. The pinned legacy Blob client matches the proven reference API;
see UPLOADING.md for its maintenance limitation, preview and publishing commands.
Configuration changes require a new revision; old output is not updated.
