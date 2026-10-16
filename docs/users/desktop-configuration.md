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

[`examples/desktop/main.luau`](../../examples/desktop/main.luau) combines settings, workspaces, and local plugins. To run an example, copy its `main.luau` and adjacent modules into the directory created above, keeping the generated `.luaurc` and configuration files.

## Change the composition

Patches target an existing entry by id or insert a local plugin's `definition`. A replacement can include its configuration. Settings and patches cannot target the same id. [`examples/keyboard/main.luau`](../../examples/keyboard/main.luau) replaces a provider; [configuration and composition](../../lua/lunette-plugin/configuration-and-composition.md) states patch ordering and validation rules.

## Menu and keyboard

The wrist menu exposes session actions, including configuration reload, the [runtime manager](runtime-manager.md), themes, and workspaces. These actions need no key chords. Reload applies source edits without closing applications.

Focusing a UI text field shows the shared keyboard. Hiding it ends focus and keeps the text. The [keyboard plugin](../../lua/lunette-plugins/input/keyboard/README.md) describes placement and replacement.

## Windows, monitors, and workspaces

Grip carries a movable panel, the thumbstick changes its distance, and a second grip resizes it. Releasing grip saves placement. The [interaction provider](../../lua/lunette-plugins/interaction/pointers/README.md) describes movement constraints.

Monitor capture may ask for screen-sharing permission. Monitor titlebars can restart or stop a mirror and, with portal capture, choose monitors again. A window's close button asks its application to close. See the [monitor controls](../../lua/lunette-plugins/panels/monitors/README.md).

Workspaces show one configured tag at a time. The wrist menu offers configured workspace names. The [workspace plugin](../../lua/lunette-plugins/workspace/controller/README.md) describes selection and placement; the desktop example configures it.

## Themes and appearance

The Appearance menu changes the theme for the current session. That choice is not saved; the `desktop/theme` settings select the starting theme. See the [theme selector](../../lua/lunette-plugins/theme/selector/README.md), or [add a theme plugin](../plugins/writing-plugins.md#add-a-theme).

## Audio backdrop

The [backdrop plugin](../../lua/lunette-plugins/environment/backdrop/README.md) can react to the system output mix and remains available without audio services. Audio capture does not change playback routing or volume. Its schema owns the options; [`examples/audio-backdrop`](../../examples/audio-backdrop) demonstrates independent audio consumers.

## Toolkit panels and notifications

The `ui-host` settings choose the toolkit's light or dark mode and its accent colour, whose contrast the theme guards, and turn touch with tracked fingertips and controller traversal on or off; the [host's options](../../lua/lunette-plugins/ui/host/config.luau) define them. The `notifications` settings set how long a toast stays, a multiplier for every timeout for users who need more time to read, and how many toasts show at once; the [notifications options](../../lua/lunette-plugins/ui/notifications/config.luau) define them. The accessibility setting for time to read and act multiplies the toast timeout as well, and each notification is announced for assistive plugins.

Default appearance renders every toolkit panel with the standard controls and the base theme, ignoring any plugin that restyles or replaces them, while the accessibility settings still apply. It is the way back from a plugin that makes the interface unusable. Holding both thumbstick clicks for a moment switches it on or off, and the wrist menu's Default appearance action does the same. With default appearance on, the plugin manager is usable again to disable or reconfigure the plugin responsible. The `ui-host` setting `appearanceChord` turns the chord off.

## Pointer and panel appearance

The [laser provider](../../lua/lunette-plugins/input/laser/README.md) configures pointer behavior. The [panels provider](../../lua/lunette-plugins/panels/service/README.md) configures window rendering. Their schemas define the options.
