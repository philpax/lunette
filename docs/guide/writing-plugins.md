# Writing plugins

A configuration is a LÖVR project whose `main.luau` can start the shipped desktop, compose plugins independently, or build another composition. A plugin declares a name, the contracts it requires or provides, and an initializer. Its resources belong to the activation that creates them and are released when that activation ends.

The examples in this guide live under `examples/` and are checked by `make check`. The [plugin facade reference](../../lua/lunette-plugin/README.md) documents definition and composition APIs. The [service contracts index](../../lua/lunette-contracts/README.md) links to each contract declaration and its service documentation. [Plugin ownership](../../lua/lunette-plugin/ownership.md) describes which layer owns lifecycle and resources. The [native API guide](native-api.md) covers native mechanisms used by plugins.

## Start a configuration

`lunette --dump-config` writes a configuration and a `.luaurc` for the installed module roots. The generated `.luaurc` resolves the installed module roots; one copied from the source tree does not resolve correctly beside an installed configuration. An uninstalled source tree can generate one with `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR`.

The default `main.luau` starts the shipped desktop:

```luau
require('@lunette-desktop').run()
```

Plugin modules can live beside the configuration and be required by relative path. A relative require resolves from the requiring file in both a session and `lunette check`. The desktop's `settings` configure built-in entries; `patches` add, replace, or disable entries. [Desktop configuration](desktop-configuration.md) describes user workflows, and [configuration and composition](../../lua/lunette-plugin/configuration-and-composition.md) describes composition rules.

## Define a consumer

A consumer uses services but does not provide one. This minimal consumer draws text through the frame service:

```luau
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'

export type Config = {}
export type Settings = {}

return plugin.consumer<<Config, Settings>>({
  name = 'hello',
  requires = { frame.capability },
  init = function(context: plugin.Context, _settings: Settings)
    local frames: frame.Service = context:require(frame.capability)
    local pose = lovr.math.newMat4():translate(0, 1.6, -1.5):scale(0.1)
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        pass:text('hello from a plugin', pose)
      end,
    })
  end,
})
```

The definition lists every required capability. The runtime activates the consumer only while a provider exists, and stops dependants before a provider deactivates. `context:require` gives the consumer a typed service. The [frame contract](../../lua/lunette-contracts/frame.luau) owns callback and draw-phase details.

Insert the returned definition into the desktop by id:

```luau
require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'hello', definition = require('./hello').definition } },
  },
}
```

## Declare a contract and provider

A contract declares a capability and the type of its service. The clock example defines a small contract:

```luau
local plugin = require '@lunette-plugin'

local clock = {}

export type Service = {
  read now: (Service) -> number,
  read elapsed: (Service) -> number,
}

clock.capability = plugin.capability<<Service>> { name = 'example/clock', version = 1 }

return clock
```

The capability name identifies its authority, and its positive version must match between providers and consumers. A capability must carry a service type for Luau to check calls through `context:require`.

A provider publishes the service returned by `build`. This excerpt assumes the plugin facade, clock contract, and `Config` and `Settings` types are in scope:

```luau
return plugin.provider<<Config, Settings, clock.Service>>({
  name = 'clock',
  capability = clock.capability,
  build = function(_context: plugin.Context, _settings: Settings): clock.Service
    local started = lovr.timer.getTime()
    return {
      now = function(_self: clock.Service): number
        return lovr.timer.getTime()
      end,
      elapsed = function(_self: clock.Service): number
        return lovr.timer.getTime() - started
      end,
    }
  end,
})
```

Only one active plugin can provide a capability. When several implementations must coexist, a broker service lets plugins register individually. The [service contracts index](../../lua/lunette-contracts/README.md) links to the declarations and registration details.

## Configuration and effects

A schema defines the plugin's configurable values. `Config` describes caller overrides; `Settings` describes the resolved values passed to the initializer or provider builder. This excerpt assumes the plugin facade and schema module are in scope:

```luau
local descriptor = schema.object { prefix = schema.default(schema.string()) 'up' }
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'uptime',
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings)
    -- A draw handler can use settings.prefix.
  end,
})
```

The definition's `define` method builds another definition with changed defaults or a name. A patch supplies a particular instance's configuration:

```luau
{ insert = { id = 'uptime', definition = require('./uptime').definition, config = { prefix = 'running for' } } },
```

Plugins register subscriptions and resources through their context or through service methods that take an owner. For example, `context:on` tracks an event subscription, and `context:resource(owner, acquire)` tracks a value together with its release function. Avoid direct subscriptions that outlive the activation. Keep state inside the initializer so each activation receives fresh state. The [ownership reference](../../lua/lunette-plugin/ownership.md) describes acquisition and release rules; the [plugin facade README](../../lua/lunette-plugin/README.md) documents context operations.

A schema field needs a default or must be optional. [Configuration schemas](configuration-schema.md) describes schema construction and merging. Three-dimensional positions, directions, and offsets use native `vector` values; colors, two-dimensional coordinates, lists, and matrices keep their domain-specific representations.

## Configure or replace an entry

Desktop settings configure built-in entries by id. A patch replaces an entry's definition and can configure that replacement, disables an entry, or inserts a new entry. A setting and a patch cannot target the same id. The checker catches type mismatches; composition validates configuration values when the desktop starts.

```luau
require('@lunette-desktop').run {
  settings = {
    laser = { style = { color = { 1, 0.4, 0.2, 0.6 } } },
  },
  patches = {
    { id = 'keyboard', definition = require('./split-keyboard').definition },
    { id = 'theme/arcade', disabled = true },
    { insert = { id = 'hello', definition = require('./hello').definition } },
  },
}
```

A patch may place an inserted entry before or after an existing entry. A definition can be a factory when each runtime start needs a fresh definition. A non-desktop composition can use `plugin.configure(id, target)` to build a type-checked configuration patch. [Configuration and composition](../../lua/lunette-plugin/configuration-and-composition.md) documents patch forms and errors. A plugin's schema and implementation define its accepted settings and defaults; its README explains how to use them and describes its controls.

## Hooks

Some providers expose hooks for changing a part of their behavior. A hook receives its normal arguments followed by `base`; calling `base` preserves the default behavior, while omitting it replaces that behavior. The keyboard example adds a press effect and keeps the default key handling:

```luau
return {
  definition = keyboard.define {
    name = 'split-keyboard',
    onKey = function(board, key, pointer, base)
      pointer:vibrate { strength = 0.2, duration = 0.01 }
      base(board, key, pointer)
    end,
  },
}
```

The [keyboard provider](../../lua/lunette-plugins/keyboard/README.md) and [interaction provider](../../lua/lunette-plugins/interaction/README.md) document their hooks and constraints. Hook errors are reported by the provider that calls them.

## Extend the keyboard

`examples/keyboard/split.luau` changes the built-in keyboard's layout and adds a numpad layer. Rows contain keys identified by an evdev code, an action, or neither for a spacer. `keyboard.Config` gives the checker the row shape; `keyboard.define` validates it at runtime. The [keyboard plugin README](../../lua/lunette-plugins/keyboard/README.md) describes its use; the [keyboard configuration](../../lua/lunette-plugins/keyboard/config.luau) defines key actions, dimensions, and drawing options.

A plugin can replace the keyboard entry with its own definition. For a full replacement that provides `lunette/keyboard`, see [`examples/keyboard/tiny.luau`](../../examples/keyboard/tiny.luau) and the [keyboard contract](../../lua/lunette-contracts/keyboard.luau) and its [input behavior](../../lua/lunette-contracts/panels-and-ui.md#keyboards). Register resources with the requesting plugin's owner so the replacement ends with that plugin.

## Add a theme

A theme plugin registers a complete theme with the theme catalog. This example starts from the standard Dark theme and changes selected colors:

```luau
local dusk = descriptors.resolve(standard.presets.dark, {
  colors = { background = { 0.10, 0.05, 0.06, 1 }, focus = { 1, 0.60, 0.25, 1 } },
})

catalog:register(context, { name = 'dusk', label = 'Dusk', order = 4, theme = dusk })
```

The registration lasts for its owner. [`examples/theme`](../../examples/theme) adds Dusk to the desktop and selects it; [the theme provider](../../lua/lunette-plugins/desktop/theme/README.md) describes selection, and the [theme contract](../../lua/lunette-contracts/theme.luau) defines theme values.

## Add a layout

Layouts register with a broker and receive the panels to arrange. The example in `examples/layout/grid.luau` registers a `grid` layout with configurable spacing and center. Its configuration inserts the plugin and selects the name:

```luau
settings = {
  ['desktop/arrange'] = { layout = 'grid' },
},
patches = {
  { insert = { id = 'grid-layout', definition = require('./grid').definition, config = { columns = 3 } } },
},
```

A layout registration ends with its plugin. [`examples/layout/follow.luau`](../../examples/layout/follow.luau) shows a continuously updated layout; the [layout service declaration](../../lua/lunette-contracts/layouts.luau) defines the service shape.

## Change pointer behavior

The interaction provider offers a `constrain` hook for changing where a carried surface goes. `examples/desktop/upright.luau` calls the default implementation, then keeps the resulting panel upright. The same example configures it through `interaction.constrain`. The [interaction provider README](../../lua/lunette-plugins/interaction/README.md) documents `drive` and `constrain`; the [laser provider README](../../lua/lunette-plugins/laser/README.md) documents button mapping and aim options.

A replacement interaction provider that moves surfaces must announce drops through the drop contract. The desktop uses drops to remember a moved window's placement. The [input guide's Drops section](../../lua/lunette-contracts/docs/input.md#drops) describes the workflow, and the [drop service declaration](../../lua/lunette-contracts/drops.luau) defines its API. The [panel and UI contracts](../../lua/lunette-contracts/panels-and-ui.md) describe related surface behavior.

## Add session controls

Plugins register session actions with the menu service. `examples/desktop/hide-windows.luau` adds an action that hides windows, and `examples/desktop/save-menu.luau` adds save and restore actions. Workflows that should remain available through VR controls use menu actions. Optional key chords register with the bindings service. The [menu and bindings contracts](../../lua/lunette-contracts/policy-services.md) describe the brokers.

The UI service creates owner-scoped VR panels with buttons, text fields, choices, lists, and custom regions. [The UI guide](ui.md) and [`examples/ui`](../../examples/ui) show a form opened from the wrist menu and edited with the shared keyboard. The [panel and UI contracts](../../lua/lunette-contracts/panels-and-ui.md) describe the shared service shapes.

## Other desktop extensions

The examples demonstrate additional extension points:

- [`examples/desktop/main.luau`](../../examples/desktop/main.luau) configures window rules, workspaces, and inserted plugins.
- [`examples/desktop/notify-errors.luau`](../../examples/desktop/notify-errors.luau) presents plugin errors as desktop notifications.
- [`examples/desktop/save-menu.luau`](../../examples/desktop/save-menu.luau) uses the arrangement service to save and restore placement.
- [`examples/audio-backdrop`](../../examples/audio-backdrop) consumes audio and analysis contracts without depending on the backdrop plugin.

Audio consumers import the neutral audio contracts, declare the required capabilities, and open readers with the plugin context as owner. The [audio contract](../../lua/lunette-contracts/audio.luau) defines sources and PCM snapshots; the [analysis contract](../../lua/lunette-contracts/audio-analysis.luau) defines reader profiles and feature snapshots. The [audio-analysis provider](../../lua/lunette-plugins/audio-analysis/README.md) describes using those features. [`examples/audio-backdrop`](../../examples/audio-backdrop) demonstrates independent consumption with a raw-level reader.

The shipped pacing and output-scale policies are configured by entry id. The [pacing consumer](../../lua/lunette-plugins/desktop/pacing/README.md) and [output-scale consumer](../../lua/lunette-plugins/desktop/scale/README.md) describe their workflows. A different policy can provide the corresponding service or replace the shipped consumer; the [policy service contracts](../../lua/lunette-contracts/policy-services.md) define the shared services.

## Check a configuration

`lunette check` typechecks configuration modules and their required modules in strict mode. It checks declared types but does not run plugin initializers. Composition rejects malformed patches. At session start, management resolves every entry's configuration before creating the runtime, so schema-invalid settings stop startup before any plugin activates. An initializer error after startup fails only that plugin's activation. The checker is the first validation step, not a substitute for starting the configuration and testing its behavior.
