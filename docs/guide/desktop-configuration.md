# Desktop configuration

A configuration is a Luau project whose `main.luau` can start the shipped desktop, compose plugins independently, or build another composition. The shipped configuration starts the default desktop with `require('@lunette-desktop').run()`. It composes providers and consumers as entries with stable ids; settings configure entries, and patches insert, replace, or disable them. The [default composition](../dev/standard-plugins.md#default-configuration) and [desktop composition reference](../../lua/lunette-plugin/configuration-and-composition.md) identify the entries and their roles. Each plugin's README describes how its settings and controls are used.

`lunette --dump-config` copies a runnable configuration and writes a `.luaurc` for the installed module roots. `lunette check` checks configuration modules without starting a session. `lunette --config-path DIR` starts the configuration in `DIR`, which holds `main.luau` and optionally `conf.luau`. [The development loop](../dev/build-and-development.md#the-development-loop) describes the repository's development configuration.

## Settings

`desktop.run` accepts settings keyed by entry id. The checker validates their types, and composition validates values when the configuration loads. Settings merge into an entry's configuration according to its schema. An entry cannot be named by both settings and patches; replace and configure it together in one patch. The plugin's configuration schema and implementation define accepted settings and defaults; its README explains how to use them and describes behavior.

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/menu'] = { hand = 'right' },
    ['desktop/keyboard'] = { placement = { distance = 0.45 } },
    ['desktop/workspaces'] = { names = { 'work', 'web' } },
  },
}
```

A misspelt or unsupported setting fails validation rather than silently changing behavior. Configuration authors can start with the shipped settings and add only the values they want to change.

## Change the composition

Patches replace, disable, or insert entries. A plugin module returns a record whose `definition` can be used in a patch. This example replaces the keyboard, removes the Arcade theme, and inserts a local HUD:

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    { id = 'keyboard', definition = require('./split-keyboard').definition },
    { id = 'theme/arcade', disabled = true },
    { insert = { id = 'my-hud', definition = require('./hud').definition } },
  },
}
```

The `insert` form can also include `config`, and can place an entry before or after another entry. `desktop.compose()` returns the default list, and `desktop.compose(options)` returns a patched list without starting the runtime. [Configuration and composition](../../lua/lunette-plugin/configuration-and-composition.md) explains patch ordering and validation. [`examples/desktop/main.luau`](../../examples/desktop/main.luau) combines settings, workspaces, and an inserted plugin.

## Menu and keyboard

The wrist menu is the entry point for session actions. Its rows come from active plugins: the built-in actions include configuration reload, the [runtime manager](runtime-manager.md), themes, and configured workspaces. The shipped desktop does not require key chords for these actions.

The shared keyboard appears when a UI text field receives focus. Hiding it ends focus without discarding the field's text. The `desktop/keyboard` setting controls its placement; the `keyboard` provider creates it. The [keyboard plugin](../../lua/lunette-plugins/keyboard/README.md) documents its options, and [`examples/keyboard/main.luau`](../../examples/keyboard/main.luau) replaces the provider.

## Windows, monitors, and workspaces

A grip on a movable panel carries it; the thumbstick adjusts its distance, and a second grip resizes it. Releasing grip saves the placement. The [interaction provider](../../lua/lunette-plugins/interaction/README.md) documents movement constraints.

The desktop mirrors host monitors. Depending on host support, capture may ask for screen-sharing permission. Monitor titlebars can restart a mirror, choose monitors again when portal capture is in use, or stop a mirror. A window's close button asks its application to close. The [monitor plugin](../../lua/lunette-plugins/desktop/monitors/README.md) describes capture behavior.

Workspaces show one configured tag at a time. The first configured name is selected at startup, and the menu offers a row for each workspace when there is more than one. For example:

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/workspaces'] = { names = { 'work', 'web' }, follow = false },
  },
}
```

The [workspace consumer](../../lua/lunette-plugins/desktop/workspaces/README.md) explains selection and placement behavior. [`examples/desktop/main.luau`](../../examples/desktop/main.luau) includes a complete workspace configuration.

## Themes and appearance

The `desktop/theme` setting selects the initial theme and overrides selected fields:

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/theme'] = {
      preset = 'light',
      overrides = { radii = { uiControl = 4 } },
    },
  },
}
```

The Appearance group in the wrist menu offers registered themes for the current session. A menu choice is not saved across sessions; set `preset` for the configured starting theme. The [theme selector](../../lua/lunette-plugins/desktop/theme/README.md) describes the settings and runtime controls. [Adding a theme](writing-plugins.md#add-a-theme) shows how a plugin registers one.

## Audio backdrop

The desktop's backdrop can react to the system output mix. Its base environment remains available without audio services. A minimal configuration enabling audio response is:

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/backdrop'] = { enabled = true, reactive = true, sourceMode = 'system' },
  },
}
```

The [backdrop plugin README](../../lua/lunette-plugins/desktop/backdrop/README.md) describes its controls and dependencies; its configuration schema and implementation define the available options and defaults. Audio capture does not change playback routing or volume, and the `audio` and `audio-analysis` providers remain independent of the backdrop so other consumers can use them. The [audio provider README](../../lua/lunette-plugins/audio/README.md) describes capture. [`examples/audio-backdrop`](../../examples/audio-backdrop) demonstrates audio consumption without coupling a consumer to the backdrop implementation. Live capture and headset checks remain [pending](../dev/audio.md#acceptance).

## Pointer and panel appearance

The `laser` setting configures both desktop pointers. For example, setting `aim.enabled = false` disables aim smoothing:

```luau
require('@lunette-desktop').run {
  settings = {
    laser = { aim = { enabled = false } },
  },
}
```

The [laser provider](../../lua/lunette-plugins/laser/README.md), [laser configuration](../../lua/lunette-plugins/laser/config.luau), and [aim and drag feedback guide](../../lua/lunette-plugins/laser/docs/aim-and-drag-feedback.md) explain pointer behavior and available settings. The [panels provider](../../lua/lunette-plugins/panels/README.md) describes window rendering options. The [theme contract](../../lua/lunette-contracts/theme.luau) defines shared appearance fields; the [panels configuration](../../lua/lunette-plugins/panels/config.luau) defines panel-specific options, and [panel appearance resolution](../../lua/lunette-plugins/panels/appearance.luau) applies them.
