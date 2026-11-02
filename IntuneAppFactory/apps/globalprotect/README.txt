Copy this entire notepadplusplus folder into apps when adding this application.

Place a real PNG named icon.png directly beside this README. Each version's
app.json uses "icon": "icon.png" to share that file. No icon image is bundled.
Set intune.icon to an empty string if no publishing icon is needed.

Place the approved installer in 8.9.7/installers using the filename in app.json.
No installer is bundled or downloaded by this example.

The example uses registry detection. An optional PowerShell detection script is
included under 8.9.7/detection. See examples/README.md in the factory for the JSON
needed to select it and instructions for adapting this folder to another app.

The builder snapshots the icon into each generated revision. Replacing this
shared icon affects future builds; existing revisions keep their saved copy.
