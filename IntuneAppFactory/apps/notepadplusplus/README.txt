Place your Notepad++ PNG icon directly in this folder and name it icon.png.
All version folders can share this one icon by setting intune.icon to "icon.png".

Example layout:
  apps/notepadplusplus/icon.png
  apps/notepadplusplus/8.9.7/app.json
  apps/notepadplusplus/8.9.7/installers/

Copy the contents of examples/notepadplusplus/ into this app folder when setting
up this application, and supply its installer before building.

No Notepad++ icon image is bundled. Supply a real PNG before building, or set
intune.icon to an empty string to omit the icon.

The builder copies the shared icon into each generated revision as icon.png.
The uploader reads that revision copy and sends it to Intune automatically.
Replacing the shared icon affects future builds; existing revisions keep their copy.
