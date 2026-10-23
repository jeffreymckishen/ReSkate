# Camera Inspector

A generic client Luau plugin for exact position/look-at camera views. It uses
the existing sandboxed camera and menu APIs plus read-only local-player state.
It has no gameplay input, teleport, freeze, files, console or network permission.

Loading it or opening its page does not acquire the camera. Open **PLUGINS →
Camera Inspector**, then **Get current view**, or prepare **Left**, **Right** or
**Front** from the current local player's position and heading. The presets only
fill the eye/target fields. Adjust distance, target height, coordinates and FOV,
then press **Apply view**. Ctrl-click a coordinate slider to type an exact value.
For manual coordinates, get or prepare a view once before applying your edits.

Exit the core Freecam, Noclip and Spectate before applying this separate camera
lease. A successful request is queued; the Camera status reports whether this
plugin actually holds the view or why it is waiting. **Release camera** always
remains available, and unloading releases the plugin's lease. Release is also
queued through the existing guarded native camera path; inspect the current
view afterwards instead of assuming the original camera has already returned.

The last readback is explicitly captured by **Get current view**. Editing or
copying fields does not move the camera or player. Presets are snapshots, never
an automatic follow mode. Coordinates are limited to the existing camera API's
100 km bounds; eye/target separation must exceed 1 cm; FOV is 40–120 degrees.

For alignment evidence, choose a fresh side or oblique view of the actual hands
and bars and record the visible result. A camera pose/readback is not proof of
renderer completion or correct hand contact. This tool contains no BMX-specific
offsets, new SDK modes, native addresses or controller schedules.

This is source for review. Nothing here launches, installs or enables the mod.
Private installation and native verification follow independent review.

Static package/API checks run with `Verify-CameraInspectorPackage.py` in the
parent directory. The actual Luau compiler/Host sandbox case is
`camera_inspector_prepares_then_explicitly_requests_a_view` in
`Extension/Plugins/Test/plugin_tests.cpp`, built by `dingosdk_plugin_tests`.
It exercises the real manifest/menu/camera API with a fake game: no automatic
ownership, explicit preparation/apply/release, invalid coordinates, permission
denial, an existing camera owner, queued/held status and unload cleanup. It does
not attach to a game. Build/run it in a quiet window before private installation;
JSON/static checks alone are not Luau compilation or native visual validation.
