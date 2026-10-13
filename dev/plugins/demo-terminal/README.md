# Development terminal

`dev/plugins/demo-terminal/init.luau` is the development-only plugin module, required as `./plugins/demo-terminal` from `dev/main.luau`. Its entry id is `dev/demo-terminal`. It starts one terminal emulator when the compositor has no windows and tries the next configured program only when the spawn itself fails.

The plugin uses the native `lunette` API directly and requires no plugin contract. [`init.luau`](init.luau) owns its schema. `programs` is an ordered list of non-empty program names and defaults to `ghostty`, `foot`, `weston-terminal`, `alacritty`, `kitty`, and `xterm`. An empty list disables startup. Existing windows also prevent startup. A session-global guard prevents a second startup attempt after a source reload; reload replaces the exit subscription but does not repeat the startup enumeration or spawn.

`dev/main.luau` inserts development plugins by relative require. Development plugins are checked and tested but are not installed and add no shipped desktop settings or aliases. See [Build and development](../../../docs/dev/build-and-development.md#the-development-loop). Tests: [`startup.luau`](tests/startup.luau).

## Known gaps

The plugin reports that no terminal emulator was found after all configured spawn attempts fail. It does not install or discover terminal applications.
