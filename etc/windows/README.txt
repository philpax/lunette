Lunette for Windows x64

Extract the ZIP to a folder under your LocalAppData directory. SteamVR
requires the folder containing the OpenVR action files to be writable only
by your account and administrators.

Run lunette.exe from that folder. For a fresh configuration, run:

    .\lunette.exe --config-path .\config

Without --config-path, Lunette uses %LOCALAPPDATA%\Lunette\config if that
directory exists. To create an editable copy with Luau editor aliases, run
lunette.exe --dump-config.

To try the OpenVR overlay alongside a SteamVR game, run SteamVR and enter
the game first. Set t.headset.backend = 'openvr' in conf.luau and keep
t.headset.overlay = true. SteamVR is installed separately.

The Windows wrist menu opens interactive application windows and monitor
mirrors. System audio capture uses the default Windows playback device.
App audio capture follows the selected process and its children on Windows
build 20348 or later.
Use lunctl.exe from the same Windows sign-in session to inspect a running
Lunette session. Set LUNETTE_CONTROL=off before startup to disable it.
Bundled notices are in the licenses folder.
