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
    bindings = { reload = { key = 'f5', modifiers = { 'control' } } },
    decorations = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
    persistence = { file = 'desktop.state' },
    wristKeyboard = { hand = 'right', placement = { distance = 0.45 } },
  },
  patches = {
    { insert = { id = 'grid-layout', definition = require './grid' } },
  },
}
```

Each section reuses the corresponding plugin module's exported `Config` type. The checker rejects a wrong value such as `wristKeyboard = { hand = 'rigth' }`. Each plugin validates its own options during initialization. A malformed plugin option fails that instance without joining the lifetimes of other entries. Unknown settings sections fail composition before LÖVR callbacks are bound.

| Settings section | Entry id |
|---|---|
| `bindings` | `desktop/bindings` |
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

The `wristKeyboard` section configures the wrist button and keyboard placement. It does not configure the `keyboard` service provider. A raw patch can replace that provider while settings configure its consumer, as in `examples/keyboard/main.luau`.

Settings merge records recursively with the entry's existing configuration. Lists and other values replace them. Composition copies and freezes the resulting entries and plain configuration tables without changing the caller's tables. A setting and a raw patch cannot name the same entry, even when the patch only disables or replaces it. Composition reports both sources. One combined raw patch supplies the configuration when replacing that entry's definition.

## Workspaces

The optional `workspaces` field reuses the configuration type of `@lunette-plugins/desktop/workspaces`. It inserts that consumer before `desktop/adoption`, so its placement listener observes windows present at boot.

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  workspaces = {
    workspaces = { { name = 'work', key = '1' }, { name = 'web', key = '2' } },
    modifiers = { 'control', 'alt' },
    follow = true,
  },
}
```

The first configured workspace is the initial selected workspace. Expansion patches `desktop/workspace` with its name and `desktop/adoption` with that name as the default tag. If the list is omitted, the consumer's default list starts with `main`. An explicit empty list or a first workspace without a non-empty name fails composition because expansion cannot determine the initial tag.

The shorthand adds one independently activated consumer. It does not merge the holder, adoption, bindings, or placement plugins. It rejects a competing `settings.workspace`, `settings.adoption`, or raw patch for `desktop/workspace`, `desktop/adoption`, or `desktop/workspaces`. It also rejects a preconfigured holder or adoption entry, or an existing workspaces consumer in an explicit entry list. Raw patches remain available for a composition with different coordination rules.

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

## Decisions

Settings expand to the existing stable-id patches so common configuration needs fewer imports without changing plugin failure, outage, or cleanup boundaries. The default retains its providers, consumers, and per-start factories.

Shorthand and raw patches cannot configure one entry together. Rejecting the collision avoids order-dependent overrides and keeps the advanced composition rule that each entry has one patch source.

Workspace expansion coordinates the initial holder and adoption defaults and runs the visibility consumer before adoption. It does not migrate explicit or persisted tags because those names are configuration and saved state, not aliases for the initial workspace.
