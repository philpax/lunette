# Desktop configuration

The shipped desktop runs from a Luau configuration. Its `main.luau` starts `@lunette-desktop`; settings change built-in entries, and patches add, replace, or disable plugins. Plugin authors can use the same configuration to [compose their own plugins](../plugins/writing-plugins.md).

## Copy and check a configuration

```sh
lunette --dump-config DIR
# Edit DIR/main.luau.
lunette check DIR
lunette --config-path DIR
```

`--dump-config` writes the runnable configuration and a `.luaurc` for the installed modules. A `.luaurc` copied from the repository resolves the wrong paths beside an installed configuration. `lunette check` checks types without running plugins; starting the session validates settings and exercises behavior. With no custom configuration, lunette runs the shipped one directly.

## Settings

`desktop.run` accepts settings keyed by entry id. The [desktop composition](../../lua/lunette-desktop/init.luau) identifies those ids. Each plugin's configuration schema defines accepted values and defaults; its README describes use and controls. Unsupported or misspelt settings fail validation.

Settings keys and patch ids do not change with plugin directories. Configurations that import shipped modules directly use the [public import migration](../../lua/lunette-plugins/README.md); removed paths do not have compatibility aliases.

The UI toolkit removed settings that a configuration may still set, and these now fail validation. The `ui` entry and its settings are gone; the UI host's settings are under `ui-host`. The errors overlay, `desktop/errors`, no longer takes `textHeight`, `columns`, `background`, `foreground`, or `font`, and the empty-desktop hint, `desktop/hint`, no longer takes `textHeight` or `font`, because the toolkit's theme sets their text and colours. The `themes`, `theme/standard`, `theme/arcade`, and `desktop/theme` entries are gone, with the Arcade theme and the Appearance menu, because one session theme now colours every surface. The `theme` entry now provides that theme, and the `mode` and `accent` settings move to it from `ui-host`. The `font` field of the `keyboard` and `panels` styles is gone too; their text uses the default face. Removing those keys from a configuration restores it.

[`examples/desktop/main.luau`](../../examples/desktop/main.luau) combines settings, workspaces, and local plugins. To run an example, copy its `main.luau` and adjacent modules into the directory created above, keeping the generated `.luaurc` and configuration files.

## Change the composition

Patches target an existing entry by id or insert a local plugin's `definition`. A replacement can include its configuration. Settings and patches cannot target the same id. [`examples/keyboard/main.luau`](../../examples/keyboard/main.luau) replaces a provider; [configuration and composition](../../lua/lunette-plugin/configuration-and-composition.md) states patch ordering and validation rules.

## Menu and keyboard

The wrist menu exposes session actions, including configuration reload, the [runtime manager](runtime-manager.md), accessibility, default appearance, and workspaces. These actions need no key chords. Reload applies source edits without closing applications.

Focusing a UI text field shows the shared keyboard. Hiding it ends focus and keeps the text. The [keyboard plugin](../../lua/lunette-plugins/input/keyboard/README.md) describes placement and replacement.

## Windows, monitors, and workspaces

Grip carries a movable panel, the thumbstick changes its distance, and a second grip resizes it. Releasing grip saves placement. The [interaction provider](../../lua/lunette-plugins/interaction/pointers/README.md) describes movement constraints.

Monitor capture may ask for screen-sharing permission. Monitor titlebars can restart or stop a mirror and, with portal capture, choose monitors again. A window's close button asks its application to close. See the [monitor controls](../../lua/lunette-plugins/panels/monitors/README.md).

Workspaces show one configured tag at a time. The wrist menu offers configured workspace names. The [workspace plugin](../../lua/lunette-plugins/workspace/controller/README.md) describes selection and placement; the desktop example configures it.

## Audio backdrop

The [backdrop plugin](../../lua/lunette-plugins/environment/backdrop/README.md) can react to the system output mix and remains available without audio services. Audio capture does not change playback routing or volume. Its schema owns the options; [`examples/audio-backdrop`](../../examples/audio-backdrop) demonstrates independent audio consumers.

## Toolkit panels and notifications

The `theme` settings choose the starting light or dark mode and accent colour, whose contrast the theme guards; the [theme options](../../lua/lunette-plugins/ui/theme/config.luau) define them. A mode or accent chosen during a session is a saved setting, which replaces those settings at the next start, as do the accessibility settings and the runtime manager's changes; the [runtime manager guide](runtime-manager.md#session-changes) describes saved settings. The `ui-host` settings turn touch with tracked fingertips and controller traversal on or off; the [host's options](../../lua/lunette-plugins/ui/host/config.luau) define them. The `notifications` settings set how long a toast stays, a multiplier for every timeout for users who need more time to read, and how many toasts show at once; the [notifications options](../../lua/lunette-plugins/ui/notifications/config.luau) define them. The accessibility setting for time to read and act multiplies the toast timeout as well, and each notification is announced for assistive plugins.

Plugin errors appear on the [error overlay](../../lua/lunette-plugins/diagnostics/error-display/README.md), a toolkit panel that shows each distinct error once with a count of its repeats. Its close button hides it until the next error, and the wrist menu's Error history action reopens every error it keeps. The `desktop/errors` settings set the panel's position and width, how many lines of each error show, how many errors the history keeps, and how many show on a page; the [overlay's options](../../lua/lunette-plugins/diagnostics/error-display/config.luau) define them.

Default appearance renders every toolkit panel with the standard controls and the base theme, ignoring any plugin that restyles or replaces them, while the accessibility settings still apply. It is the way back from a plugin that makes the interface unusable. Holding both thumbstick clicks for a moment switches it on or off, and the wrist menu's Default appearance action does the same. With default appearance on, the plugin manager is usable again to disable or reconfigure the plugin responsible. The `ui-host` setting `appearanceChord` turns the chord off.

## Pointer and panel appearance

The [laser provider](../../lua/lunette-plugins/input/laser/README.md) configures pointer behavior. The [panels provider](../../lua/lunette-plugins/panels/service/README.md) configures window rendering. Their schemas define the options.

While the lunette desktop window has mouse input, the mouse aims a ray from the head through a cursor in the scene, and its buttons and wheel click and scroll whatever the cursor is over. The cursor appears after the mouse first moves and turns with the head. The `desktop/mouse-pointer` settings set the sensitivity, the cone the cursor stays within, the wheel's scroll and push scales, and the cursor's size, distance, and colours; the [mouse pointer's options](../../lua/lunette-plugins/input/mouse-pointer/config.luau) define them. The mouse is not captured from the host, so it reaches the scene only through the desktop window.
