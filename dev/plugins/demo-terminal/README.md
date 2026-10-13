# Development terminal

Starts one terminal emulator when the compositor has no windows. Configure [`programs`](init.luau) as an ordered list; the plugin tries the next name only when spawning a program fails. An empty list disables startup.

The plugin runs from `dev/main.luau` and uses the native `lunette` API directly. It is development-only and is not installed with the shipped plugins. See [Build and development](../../../docs/dev/build-and-development.md#the-development-loop).
