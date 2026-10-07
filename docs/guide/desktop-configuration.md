# Desktop configuration

The shipped configuration starts the default desktop with `require('@lunette-desktop').run()`. `lua/lunette-desktop/init.luau` owns the default entries and the configuration types. Its settings expand into patches for those entries. Each provider and consumer remains independently replaceable and retains its own runtime lifetime.

`lunette --dump-config` copies the shipped configuration and writes a `.luaurc` that names the installation's module roots. A custom configuration uses that directory. `lunette check` checks the configuration without starting a session. The checked configurations under `examples/desktop/`, `examples/keyboard/`, and `examples/layout/` demonstrate settings, provider replacement, and layout registration.

An alternate configuration starts with `lunette --config-path /path/to/config`. The path names a directory containing `main.luau` and, optionally, `conf.luau`. A relative path resolves from the working directory. The shipped desktop opens no application automatically. The repository's `dev/` configuration adds a terminal plugin for development; [The development loop](../dev/build-and-development.md#the-development-loop) states its launch command.

## Settings

`desktop.run` and `desktop.compose` accept the same options. Common consumer options go in `settings`, without importing each consumer's definition or factory.

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    menu = { hand = 'right' },
    decorations = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
    persistence = { file = 'desktop.state' },
    wristKeyboard = { placement = { distance = 0.45 } },
  },
  patches = {
    { insert = { id = 'grid-layout', definition = require './grid' } },
  },
}
```

Each section reuses the corresponding plugin module's exported `Config` type. The checker rejects a wrong value such as `menu = { hand = 'rigth' }`. `desktop.compose` parses the declared settings and expands them into entry patches before activation, so an invalid settings value aborts composition. When `plugin.start` or the native runtime starts definitions directly, configuration validation occurs as each instance activates; an invalid value fails that instance without aborting other entries. Unknown settings sections fail composition before LÖVR callbacks are bound.

| Settings section | Entry id |
|---|---|
| `menu` | `desktop/menu` |
| `decorations` | `desktop/decorations` |
| `arrange` | `desktop/arrange` |
| `persistence` | `desktop/persistence` |
| `wristKeyboard` | `desktop/keyboard` |
| `rules` | `desktop/rules` |
| `monitors` | `desktop/monitors` |
| `hint` | `desktop/hint` |
| `errors` | `desktop/errors` |
| `pointing` | `desktop/pointing` |
| `pacing` | `desktop/pacing` |
| `workspace` | `desktop/workspace` |
| `adoption` | `desktop/adoption` |
| [`manager`](runtime-manager.md) | `desktop/manager` |

The `menu` section configures the wrist Menu control in `desktop/menu`. Its descriptor and defaults are in `lua/lunette-plugins/desktop/menu/config.luau`. It accepts `hand`, `size`, a vector `offset`, `haptic`, and `expanded` panel dimensions. The default hand is `left`, the compact size is 0.115 metres, and the offset is `vector.pack(-0.03, -0.01, 0.125)`. The expanded panel defaults to 0.32 by 0.4 metres and 320 by 400 logical pixels, with a row height of 40 logical pixels. Haptics default to strength 0.3 and duration 0.05 seconds.

The `wristKeyboard` section configures only keyboard placement in `desktop/keyboard`. Its descriptor is in `lua/lunette-plugins/desktop/keyboard/config.luau`; `placement.distance`, `placement.drop`, and `placement.tilt` default to 0.55 metres, 0.35 metres, and `math.pi / 6` radians. It does not configure the `keyboard` service provider. A raw patch can replace that provider while settings configure the display provider, as in `examples/keyboard/main.luau`. `desktop/keyboard` publishes `lunette/keyboard-display` and lazily reuses one board. Focusing a local text field shows that board; switching fields keeps its pose. A manual show keeps it visible after editing ends. Explicit hide or the board's Hide action ends the matching field focus without discarding its draft.

`settings.bindings` and the shipped `desktop/bindings` entry are removed. Reload uses the wrist menu. The neutral `bindings` provider remains available for custom input bindings. The `hand`, `size`, `offset`, and `haptic` fields of `settings.wristKeyboard` are removed; configurations place them in `settings.menu` instead. Composition reports these removed settings rather than ignoring them.

Settings follow the entry's configuration descriptor. Declared objects merge recursively with the entry's existing configuration. Arrays, maps, unions, and atomic values replace; an empty map clears its previous keys. Composition copies and freezes descriptor-declared object and collection containers. Callback and custom values retain their exact references, and non-plain native values such as vectors retain their values. For a factory entry, composition retains configuration layers until the factory supplies a definition. The definition's descriptor then determines merging and copying; managed preflight or instance activation performs validation. A setting and a raw patch cannot name the same entry, even when the patch only disables or replaces it. Composition reports both sources. One combined raw patch supplies the configuration when replacing that entry's definition.

## Wrist menu

`desktop/menu` renders the wrist Menu button and its expanded action list through the neutral `lunette/ui` contract. The tracked configured hand carries the control. A laser trigger press and release on Menu opens the action list; Close returns to the compact button. The list scrolls when its actions exceed the visible area. Tracking loss hides and closes the menu and cancels an armed action. A cancelled gesture cannot activate an action after tracking returns.

`desktop/actions` registers Keyboard and Reload configuration with the neutral `lunette/menu` broker. Keyboard toggles the shared keyboard display, and its selected state follows the display's visibility. An owner-scoped child registers Keyboard, so a display outage removes only that action. Reload configuration remains available to reload the configuration and its source modules. The shipped desktop registers no physical reload chord.

`desktop/manager` registers Plugins, which opens the shared-UI manager panel named `desktop/manager`. The graph and scrollable sidebar rows use custom regions; buttons, text fields, and choices use shared `lunette/ui` controls. Controller input reaches search, configuration editing, graph navigation, inspection, lifecycle actions, recovery, catalog loading, and Close. Search and configuration text fields use the same desktop keyboard instance as application input. Close hides the panel and ends its active field focus. The manager no longer registers physical key or text handlers. Its schema rejects the removed `toggleKey` option and reports that Plugins opens the manager from the session menu. The [runtime manager guide](runtime-manager.md) describes the controls and session-only limits.

The [desktop example](../../examples/desktop/main.luau) inserts `hide-windows` and `save-menu`. They register Hide windows, Save arrangement, and Restore arrangement in the menu's Examples group. They are optional example consumers, not default session actions.

## Workspaces

The optional `workspaces` field reuses the configuration type of `@lunette-plugins/desktop/workspaces`. It inserts that consumer before `desktop/adoption`, so its placement listener observes windows present at boot.

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  workspaces = {
    workspaces = { { name = 'work' }, { name = 'web' } },
    follow = true,
  },
}
```

The first configured workspace is the initial selected workspace. Expansion patches `desktop/workspace` with its name and `desktop/adoption` with that name as the default tag. `lua/lunette-plugins/desktop/workspaces/config.luau` owns the defaults: `main`, `two`, `three`, and `four`, with `follow = true`. The list requires unique, non-empty names and at least one workspace. Each workspace accepts only `name`; `key` and `modifiers` are removed and report migration errors.

A child consumer registers each workspace name in the menu's Workspaces group. Selecting its row switches the selected workspace, and the row's selected state follows the tag selection. A menu outage removes those actions without changing workspace selection, visibility, or follow policy.

The shorthand adds one independently activated consumer. It does not merge the holder, adoption, menu, or placement plugins. It rejects a competing `settings.workspace`, `settings.adoption`, or raw patch for `desktop/workspace`, `desktop/adoption`, or `desktop/workspaces`. It also rejects a preconfigured holder or adoption entry, or an existing workspaces consumer in an explicit entry list. Raw patches remain available for a composition with different coordination rules.

Expansion does not rewrite explicit rule tags or persisted tags. Tags absent from the configured workspace list remain outside this consumer's visibility and follow policy. With `follow = true`, a newly placed panel already in a configured workspace follows the currently selected workspace, including a boot placement from a rule or saved arrangement. `follow = false` preserves that membership. Renaming a workspace does not migrate the saved arrangement; existing saved tag names still apply.

## Entry patches

`entries` replaces the default entry list. `patches` retains the full composition API: configure, replace, disable, or insert entries by stable id. `desktop.entries()` exposes the default list, and `desktop.compose(options)` returns the frozen expanded list without starting any plugins. A missing settings target in a custom list raises a composition error.

`plugin.configureEntry(id, target)(config)` makes a typed configuration patch for an actual entry id. The target is a definition or definition factory that supplies the configuration type. The helper never invokes a factory. The desktop exports the same helper as `desktop.configureEntry`.

```luau
local desktop = require '@lunette-desktop'
local persistence = require '@lunette-plugins/arrangement'

local entries = desktop.compose {
  patches = {
    desktop.configureEntry('desktop/persistence', persistence.factory) { file = 'desktop.state' },
  },
}
```

The supplied id may differ from the definition's name. The patch only carries the id and configuration; it does not replace the definition. A factory still runs once per runtime start, and its returned definition survives provider outages within that runtime. Separate starts construct fresh definitions.

The existing `plugin.configure(target)(config)` and `desktop.configure(target)(config)` remain compatible. They use the definition's name as the id and invoke a factory to discover that name. `configureEntry` is the appropriate helper when an id differs from a name or configuration must not construct a definition.

[Writing plugins](writing-plugins.md) describes provider substitution and plugin authoring. The [desktop example](../../examples/desktop/main.luau) combines settings, typed entry patches, workspaces, and inserted plugins.

## Known gaps

The manager exposes search and configuration fields through the shared UI controls and shared keyboard. `toggleKey` is removed; the manager configuration schema reports a migration diagnostic for configurations that still set it. Logic-headless behavior does not establish XR or GPU-backed behavior, host-desktop acceptance, or installed-session execution. Manual headset acceptance remains open for readability, controller ergonomics, shaping, bidirectional editing, and IME behavior.

## Decisions

The wrist menu uses UI controls and menu actions so the shipped keyboard, reload, and workspace controls do not require physical key chords. The neutral bindings provider remains available for custom inputs. Keyboard placement stays in `wristKeyboard` for configurations that change the shared display without changing wrist geometry.

Settings expand to the existing stable-id patches so common configuration needs fewer imports without changing plugin failure, outage, or cleanup boundaries. The default retains its providers, consumers, and per-start factories.

Shorthand and raw patches cannot configure one entry together. Rejecting the collision avoids order-dependent overrides and keeps the advanced composition rule that each entry has one patch source.

Workspace expansion coordinates the initial holder and adoption defaults and runs the visibility consumer before adoption. It does not migrate explicit or persisted tags because those names are configuration and saved state, not aliases for the initial workspace.
