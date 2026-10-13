# Writing plugins

A lunette configuration is a LÖVR project whose `main.luau` composes the shipped desktop and adds or replaces plugins in it. A plugin is a definition: a name, the contracts it requires and provides, and an initializer that runs when the plugin activates. The plugin runtime releases everything an activation acquired when that activation ends.

The code in this guide comes from the configurations under `examples/`: `first-plugin`, `keyboard`, `layout`, `theme`, `ui`, `desktop`, and `audio-backdrop`. `make check` typechecks them and runs their desktop or independent consumer tests. [The Lua API](../dev/lua-api.md#plugin-authoring) is the specification this guide follows. [The native API](native-api.md) describes the `lunette` module beneath the plugins.

## A configuration to work in

`lunette --dump-config` writes `main.luau`, `conf.luau`, and a `.luaurc` to `$XDG_CONFIG_HOME/lunette`, or to a directory given after the flag. The `.luaurc` names the installed Lua roots by absolute path, which lets `lunette check` and an editor resolve `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`. A `.luaurc` copied by hand from the source tree names relative paths that do not exist beside the copy. From an uninstalled source tree, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` writes a `.luaurc` that names the tree's roots.

The shipped `main.luau` is one call:

```luau
require('@lunette-desktop').run()
```

`run` takes `settings` and `patches`. [Desktop configuration](desktop-configuration.md) describes the settings. [Default configuration](../dev/standard-plugins.md#default-configuration) lists the shipped composition. Patches change the desktop's entry list, which `require('@lunette-desktop').compose()` returns. Each entry has an `id`, such as `keyboard`, `laser`, or `desktop/keyboard`. The built-in providers publish services such as panels, pointers, and the keyboard, and the `desktop/` consumers use them. Every entry is a module under `@lunette-plugins`: a provider under its contract's name and any other plugin under its entry id, so `desktop/menu` is `@lunette-plugins/desktop/menu`, and `desktop/keyboard`, which provides `lunette/keyboard-display`, is `@lunette-plugins/keyboard-display`.

Plugin modules live in the configuration directory and are required by relative path, such as `require './hello'`. A relative path resolves against the directory of the requiring file, in a session and in `lunette check` alike. From `myplugin/init.luau`, `require '@self/draw'` names `myplugin/draw.luau`, because `./draw` from an `init.luau` names a sibling of its directory. A relative path cannot leave the configuration directory. [Module roots](../dev/build-and-development.md#module-roots) states the rules.

## A first plugin

`examples/first-plugin/hello.luau` draws a line of text over the scene:

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

`plugin.consumer` takes `name`, `requires`, `schema`, and `init`; `requires` and `schema` are optional. `requires` lists the capabilities of the contracts the plugin uses, here the frame contract, which delivers LÖVR's update, draw, key, text, and quit callbacks. `context:require` returns the service behind a required contract. `frames:onDraw(context, ...)` registers a draw handler owned by the plugin's context. The draw phases run in the order `input`, `scene`, `pointing`, `overlay`, and `feedback`.

The module returns the record `plugin.consumer` makes, and every plugin module returns such a record. Its `definition` field is what an entry names. The configuration inserts the plugin as a new entry:

```luau
require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'hello', definition = require('./hello').definition } },
  },
}
```

## Contracts and capabilities

A contract is a module that declares a capability and the type of the service behind it. `examples/first-plugin/clock.luau` is one:

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

`plugin.capability<<Service>>` attaches the service type, so `context:require(clock.capability)` returns a `clock.Service` that the checker reads. `lunette check` reports a capability declared without a service type. The name is qualified by an authority, here `example`. The version is a positive integer that the provider and its consumers must share.

A plugin that requires a contract is active only while some plugin provides it. When a provider deactivates, every plugin that requires it deactivates first, and each reactivates when a provider returns. A plugin therefore contains no code for a missing service.

## Providing a service

`examples/first-plugin/clock-provider.luau` publishes the clock:

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

`plugin.provider` takes `name`, `capability`, `requires`, `schema`, and `build`, and publishes what `build` returns. A consumer receives a read-only view of the service. A method called through the view after the provider's activation ends raises an error naming the contract. Two active plugins cannot provide the same contract.

## Effects, ownership, and options

`examples/first-plugin/uptime.luau` declares an option, counts opened windows, and draws the elapsed time:

```luau
local descriptor = schema.object { prefix = schema.default(schema.string()) 'up' }
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'uptime',
  requires = { frame.capability, clock.capability },
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings)
    local frames: frame.Service = context:require(frame.capability)
    local time: clock.Service = context:require(clock.capability)
    local opened = 0
    context:on {
      event = lunette.onWindowOpened,
      run = function(_event: lunette.WindowOpenedEvent)
        opened += 1
      end,
    }
    -- The draw handler formats settings.prefix, time:elapsed(), and opened.
  end,
})
```

A plugin changes state outside itself only through its context. `context:on` subscribes to a native event for the length of the activation. `context:effect` registers any other resource with the function that releases it. A service method that takes an owner, such as `frames:onDraw(context, ...)` or `keyboard:new(context)`, ties what it creates to that owner. A direct `lunette.onWindowOpened(handler)` call is not tracked: the subscription outlives the plugin, and a reactivated plugin subscribes again. State declared inside `init` belongs to one activation.

The context offers these operations, and each ties what it creates to the activation:

- `context:effect(acquire)` runs `acquire`, which returns the function that undoes it.
- `context:acquire(owner, acquire)` is the usual form for a provider method: it checks that `owner` is the provider's own context or a plugin that requires the provider, and registers the release on that owner.
- `context:resource(owner, acquire)` is the same for an `acquire` that returns a value and the function that releases it, and returns the value.
- `context:on { event, run }` subscribes to a native event.
- `context:child(definition, config?)` installs and enables a plugin that ends with this one.
- `context:active()` reports whether the activation can still acquire resources.

When an activation ends, its effects are undone in the reverse of the order they were registered. An effect created while another effect's `acquire` runs is registered first, so it is undone after the outer one; an outer release that depends on the inner one being gone releases it itself. A service method that takes an owner registers its resource on that owner, so a plugin passes its own `context` and the resource ends with the plugin.

A schema declares the options. `Config` is the type of the caller's overrides and `Settings` the type of the resolved value passed to `init`. A plugin without a `schema` takes no options. Every field needs a default or an optional descriptor, because the facade resolves an empty configuration when it builds the definition. [Configuration schemas](configuration-schema.md) describes the constructors and merge rules.

The record has `definition`, built from the defaults, and `define`, which makes another definition with other defaults and an optional `name`. An insert supplies configuration:

```luau
{ insert = { id = 'uptime', definition = require('./uptime').definition, config = { prefix = 'running for' } } },
```

Geometric positions, directions, and offsets are native `vector` values made with `vector.pack(x, y, z)`. Vectors are immutable, so `direction = direction:normalize()` keeps the returned value. `Mat4:translate` accepts a vector. Colours, two-dimensional coordinates, lists, and full matrices keep their own representations.

## Hooking a built-in provider

Behaviour inside a provider changes through a hook: an option whose value is a function that receives the hook's arguments followed by `base`, the default implementation. Calling `base` keeps the default, and not calling it replaces it. The built-in hooks are the keyboard's `onKey` and `drawKey`, interaction's `drive` and `constrain`, the laser's `readInput` and `draw`, placement's `panelOptions`, and a UI control's `draw`. An error a hook raises is reported where the provider was called from. The [UI rendering page](../../lua/lunette-plugins/ui/docs/rendering.md) specifies the UI draw hook's rendering boundary; this guide retains the shared hook contract.

Only one active plugin can provide a contract. Where several implementations coexist, as with layouts, themes, menu actions, key bindings, rule sources, and surface offers, one provider is a broker and each implementation registers with it. A name registered with a broker has one holder at a time, and registering a taken name raises an error.

## Configuring a built-in plugin

The desktop's `settings` configure its entries by id. Each value has the type of the entry's `Config`, so the checker rejects a wrong value type, such as `['desktop/keyboard'] = { placement = { distance = 'far' } }`, and composition validates every setting when the configuration loads:

```luau
require('@lunette-desktop').run {
  settings = {
    laser = { style = { color = { 1, 0.4, 0.2, 0.6 } } },
    ['desktop/keyboard'] = { placement = { distance = 0.45 } },
  },
}
```

A setting merges into the entry's configuration through the definition's schema: declared objects merge field by field, and arrays, maps, unions, and scalar values replace. A misspelt key is not a Luau type error; runtime validation rejects it with an error naming its path. [Contracts and providers](../dev/standard-plugins.md#contracts-and-providers) lists the built-in providers and their options.

Patches change the entry list. A patch with an entry's `id` and `definition` replaces what the entry is made from, with an optional `config` for the new definition, and `disabled = true` removes the entry. An `insert` patch adds an entry at the end, or `before` or `after` a named entry. A patch naming an unknown id, two patches naming one id, or a setting and a patch naming one id raise an error when the configuration loads. A definition is a plugin definition or a factory that makes one; a factory makes a fresh definition each time the runtime starts.

A composition built without the desktop configures an entry with `plugin.configure(id, target)`, which returns a function that makes a configuration patch typed with the target's options. The target is the entry's definition; composition raises when the entry with that id is made from another one.

## Independent audio consumption

`examples/audio-backdrop/meter.luau` is a consumer of `lunette/frame`, `lunette/audio`, and `lunette/audio-analysis`. It imports their neutral contracts and does not import the desktop, backdrop, or analysis implementation. The [audio](../../lua/lunette-plugins/audio/README.md) and [audio-analysis](../../lua/lunette-plugins/audio-analysis/README.md) provider pages describe their implementations. Its `main.luau` inserts it into the complete default desktop, while its local tests run it with only the real frame, audio, and analysis providers over the fake native boundary. The same plugin can run in a composition with no backdrop.

A raw reader opens with the caller's owner and a source descriptor:

```luau
local audio = require '@lunette-contracts/audio'
local analysis = require '@lunette-contracts/audio-analysis'

local source: audio.Source = { kind = 'system' }
local raw = context:require(audio.capability):open(context, source)
local result = context:require(analysis.capability):open(context, source)
if result.kind == 'success' then
  local features = result.reader
  -- An update handler reads raw:snapshot() and features:snapshot().
else
  error(result.kind .. ': ' .. result.detail)
end
```

The definition declares both capabilities in `requires`. Both readers end with the context; `close()` can release either earlier. Equal sources share native capture, and equal analysis profiles share work. A process source is `{ kind = 'process', process = handle }`, where the handle comes from the session's native process or window association. Neither a PID nor an application name selects a source. Handles belong to the session and are not saved in configuration or preferences.

A raw snapshot contains the source, state, frame publication generation, and immutable blocks. `block:copySamples()` returns a fresh buffer of interleaved little-endian F32 samples. Its byte length is `block.frameCount * block.channels * 4`. `buffer.readf32(samples, index * 4)` reads one sample at a zero-based index. `raw-level.luau` reads at most 256 frames from the newest block to demonstrate this boundary; it does not replace the reusable streaming analysis. The raw block's stream generation and sequence identify discontinuity and duplicate data, and its `gap` and `droppedFrames` report loss.

The analysis open result distinguishes success, invalid options, and exhausted profile capacity. `size` is 512, 1024, or 2048, and `hop` is a quarter or half of that size. The default profile is 2048/512. A feature snapshot has `state`, `frameGeneration`, optional stream `generation`, optional `endFrame`, `gap`, optional `gapReason`, `droppedFrames`, completed `hops`, and optional `latest` steady values. Each steady value has RMS, peak, bass, mid, and treble powers, and an eight-band `spectrum` of powers from low to high. Each hop adds full-band `flux` and `onset`, and `bassOnset`, `midOnset`, and `trebleOnset`, which register events in one band, such as a kick or a hi-hat. State loss, generation changes, sequence or sample-time discontinuities, capacity loss, invalid samples, and reader termination clear `latest` until a fresh complete window. Continuous active publications without a completed hop retain steady values. An empty `hops` list does not replay flux or onset. Snapshot `endFrame` is the optional exclusive cumulative end of the last processed PCM block within its stream generation. It is absent before the first processed block, advances for blocks that complete no hop, and stays unchanged when no new PCM arrives. A hop's `endFrame` is the exclusive end of its completed window; compare it with the snapshot end only when their stream generations match. [Audio](../dev/audio.md#lua-analysis) specifies shared sample-time semantics, normalisation, and budgets. The [audio-analysis provider](../../lua/lunette-plugins/audio-analysis/README.md) and its [analysis details](../../lua/lunette-plugins/audio-analysis/docs/analysis.md) describe provider behavior; the contract modules still own the exact shapes consumed by this plugin.

`dev/plugins/audio-diagnostics` is a repository-only opt-in consumer of the same contracts. It logs source identity, state, format, sequence, loss, generation, band powers, and attribution provenance without a draw handler. It observes every publication and reports accumulated gap, dropped-frame, and generation-change counts at each logging interval, so a later clean publication does not hide transient loss. Raw and analysis loss counters are separate views of the same stream and must not be added together. Its default `enabled = false` opens no reader. A development configuration can insert it through a relative require with `{ enabled = true }`; it is not installed, adds no alias, and is not enabled by the default development desktop. Synthetic signals stay in tests or development code. Live PipeWire and headset acceptance remain [pending](../dev/audio.md#acceptance).

## Themes

`desktop/theme` selects the theme through `lunette/theme`. A configuration names the initial theme and can override fields of it:

```luau
settings = {
  ['desktop/theme'] = {
    preset = 'arcade',
    overrides = {
      colors = { focus = { 1, 0.5, 0.1, 1 } },
      typography = { bodySize = 20 },
    },
  },
},
```

[Runtime themes](desktop-configuration.md#runtime-themes) describes the selector and its menu.

A plugin reads the theme through `@lunette-contracts/theme`. `theme.Theme` is a complete immutable value with `colors`, `typography`, `metrics`, and `radii`. `service:current()` returns `{ revision, theme }`, and `service:onChanged(owner, { run })` calls `run` with a new snapshot after each change. `service:font(spec)` returns the font face for a `theme.FontSpec`, or for the current theme's font when `spec` is omitted. The provider caches one face per specification, so a plugin asks again after a theme change instead of keeping a face. `service:select(owner, overrides)` returns a registration whose overrides apply over the base theme; the most recent live registration wins. [Runtime themes](../dev/lua-api.md#runtime-themes) specifies the contract.

The built-in UI, keyboard, panels, and laser read the theme provider, so a custom composition that uses them includes the `theme` entry.

## Adding a theme

The themes that `desktop/theme` offers come from the `lunette/themes` catalog. A plugin adds one by registering a complete theme under a name, and the theme's menu row lasts as long as the registration. `examples/theme/dusk.luau` registers Dusk, the standard Dark theme with a warmer palette:

```luau
local dusk = descriptors.resolve(standard.presets.dark, {
  colors = { background = { 0.10, 0.05, 0.06, 1 }, focus = { 1, 0.60, 0.25, 1 } },
})

catalog:register(context, { name = 'dusk', label = 'Dusk', order = 4, theme = dusk })
```

`descriptors.resolve` fills omitted fields from the theme it starts from, here Dark. `order` places the row among Dark at 1, Light at 2, and Arcade at 3. Registering a name that another live registration holds raises an error. The [theme catalog](../../lua/lunette-plugins/themes/README.md), [standard presets](../../lua/lunette-plugins/theme/standard/README.md), and [Arcade preset](../../lua/lunette-plugins/theme/arcade/README.md) describe the shipped registrations.

`examples/theme/main.luau` inserts the plugin, names Dusk as the selector's `preset`, and disables `theme/arcade`. Arcade is an ordinary plugin of this kind, so disabling its entry removes its row. [Runtime themes](../dev/lua-api.md#runtime-themes) states the contract.

## Extending the built-in keyboard

`@lunette-plugins/keyboard` is a provider module, so `keyboard.define` makes a keyboard definition with other options. `examples/keyboard/split.luau` is the built-in keyboard with split rows, a numpad layer, a click on every key, and a flash on the pressed key.

Rows are lists of keys. A key has an evdev `code` from `@lunette-contracts/keys`, an `action`, or neither, which makes it a spacer. `width`, `height`, and `x`, the gap before the key, are in key units. Legends come from the focused seat's keymap. An action is `hide`, `layer`, `text`, `chord`, or `custom`.

```luau
local letters: keyboard.Config = {
  rows = {
    -- ...
    {
      { action = { kind = 'layer', layer = 'numpad' }, label = '123' },
      { code = codes.space, label = 'space', width = 3 },
      { code = codes.space, label = 'space', width = 3, x = SPLIT },
      { action = { kind = 'chord', code = codes.t, modifiers = { 'control', 'alt' } }, label = 'term' },
      { action = { kind = 'hide' } },
    },
  },
}
```

The `keyboard.Config` annotation lets the checker read each key. `define` validates the rows at runtime as well and raises an error naming the key by path, such as `rows[1][1]`. A key with `height = 2` reaches into the next row, which leaves a spacer where it reaches.

Two hooks change behaviour without copying it. Each receives its arguments and then the default, which it calls to keep the default behaviour. `onKey` runs for every key a pointer presses, and `drawKey` for every key drawn:

```luau
return {
  definition = keyboard.define {
    name = 'split-keyboard',
    rows = letters.rows,
    layers = { numpad = numpad.rows },
    style = { keyUnit = 0.03 },
    onKey = function(board, key, pointer, base)
      pointer:vibrate { strength = 0.2, duration = 0.01 }
      pressedAt[key.source] = lovr.timer.getTime()
      base(board, key, pointer)
    end,
    drawKey = function(pass, key, state, base)
      -- A recently pressed key draws a lit face and the default legend; others call base.
    end,
  },
}
```

`pointer:vibrate` pulses the controller that pressed the key. `key.source` is the row entry the key was made from and stays the same table across frames. `@lunette-plugins/keyboard/draw` has the default drawing's parts, including `legend`. The built-in key and backing radii already follow the theme, so rounding needs no hook.

The definition replaces the desktop's keyboard by id, and every plugin that requires the keyboard contract then receives it:

```luau
{ id = 'keyboard', definition = require('./split').definition },
```

## Replacing the keyboard

A plugin that provides `lunette/keyboard` at schema 3 can take the keyboard entry's place. `service:new(owner, options)` returns a keyboard, which is a surface with `setVisible`, `draw`, and `destroy`, and `service:inspect()` returns its registrations. A replacement sends the keys a pointer presses through a virtual focus source and reports visibility changes through `options.onVisibilityChanged`, the only option. [Keyboard](../dev/lua-api.md#keyboard) and [Keyboard routing](../dev/input.md#keyboard-routing) specify the rules. `examples/keyboard/tiny.luau` implements the contract with one row of three keys.

The example acquires each board with `context:resource(owner, acquire)`. The acquisition returns the board and the function that releases it, and `context:resource` registers that release with the owner, so a keyboard ends with the plugin that asked for it. An acquisition that raises before it returns must release what it had already acquired.

Luau gives a function with no expected type the return type of its first `return`. A `raycast` method written outside an annotated surface table is therefore annotated `(number?, number?, number?)`, or a miss returning `nil, nil, nil` fixes the wrong type.

## Local VR controls

The [UI guide](ui.md) describes owner-scoped flat VR panels with buttons, text fields, choices, lists, and custom regions through the `lunette/ui` contract. Its example is `examples/ui`, a form opened from the wrist menu that edits text with the shared desktop keyboard.

## A custom layout

`desktop/arrange` arranges windows that no rule or saved arrangement placed, with a layout it names. A layout is a function that poses a list of panels, registered by name with the `lunette/layouts` broker. The desktop registers `arc`. `examples/layout/grid.luau` registers `grid`:

```luau
local descriptor = schema.object {
  columns = schema.default(schema.number { minimum = 0, integer = true })(0),
  gap = schema.default(schema.number())(0.08),
  center = schema.default(schema.vector())(vector.pack(0, 1.5, -1.8)),
}

local function grid(panels: { read [number]: layouts.Panel }, options: Settings): ()
  -- Poses each panel in a grid cell with panel:setPose.
end

-- In the consumer's init, which receives the entry's settings:
service:register(context, {
  name = 'grid',
  apply = function(panels: { read [number]: layouts.Panel }): ()
    grid(panels, settings)
  end,
})
```

The layout receives a read-only list of live panels. `desktop/arrange` passes the adopted windows of a tag that were placed without a pose and that the user has not dragged. The layout's options are its plugin's configuration, so the schema validates them when the configuration loads. The registration ends with the plugin, and registering a name twice raises an error.

The configuration inserts the plugin with its options and selects the layout:

```luau
settings = {
  ['desktop/arrange'] = { layout = 'grid' },
},
patches = {
  { insert = { id = 'grid-layout', definition = require('./grid').definition, config = { columns = 3 } } },
},
```

The built-in `arc` takes its options the same way, as `settings['layout/arc'] = { tuning = { radius = 2 } }`. `desktop/arrange` arranges every tag with its one layout, and arranges again when a layout registers, and logs a warning after the first frame if its chosen layout is not registered. [Standard plugins](../dev/standard-plugins.md#placement) describes how layout selection fits into the shipped composition.

A layout registered with `continuous = true` is applied every frame. `examples/layout/follow.luau` keeps windows on an arc that turns to follow the head, reusing `@lunette-plugins/layout/arc/geometry`. To replace `arc`, disable the `layout/arc` entry and register another layout under that name, or give `layout/arc` another `name`.

## Changing how pointers behave

The interaction provider turns each frame of a laser's input into hovering, clicking, scrolling, and carrying. It takes two hooks as options. `constrain(surface, pose, base)` returns where a carried surface goes. `examples/desktop/upright.luau` keeps carried panels level:

```luau
local interaction = require '@lunette-plugins/interaction'
local vocabulary = require '@lunette-contracts/vocabulary'

return function(target: vocabulary.Surface, pose: Mat4, base: interaction.ConstrainBase): Mat4
  local kept = base(target, pose)
  local x, y, z = kept:getPosition()
  local forwardX, _, forwardZ = kept:mul(0, 0, -1, 0)
  local yaw = math.atan2(-forwardX, -forwardZ)
  return lovr.math.newMat4():translate(x, y, z):rotate(yaw, 0, 1, 0)
end
```

```luau
settings = {
  interaction = { constrain = require './upright' },
},
```

`drive(pointer, input, surfaces, base)` runs every frame for every pointer, and `base` maps grip to grab, buttons to clicks, and the stick to scrolling or reach. A hook that calls `base` with changed input remaps it. A hook that does not call `base` drives the pointer's `hover`, `setButton`, `beginGrab`, `dragTo`, and `endGrab` itself, and `@lunette-plugins/interaction/picking` has the default picking and scrolling. `focusOnPress = false` stops a click from moving keyboard focus.

The laser's `buttons` option maps controller buttons to pointer buttons, and a list replaces the default:

```luau
settings = {
  laser = {
    buttons = {
      { control = 'trigger', button = 'left' },
      { control = 'a', button = 'right' },
    },
  },
},
```

A plugin that moves surfaces for a pointer, as a replacement interaction would, announces each drop through `lunette/drops`. The desktop remembers a dropped window's place and saves the arrangement only on those drops.

## Menu actions and key bindings

Session controls are menu actions, because every session workflow is reachable with VR controllers. A plugin registers an action with `lunette/menu`, and the wrist menu draws it. `examples/desktop/hide-windows.luau` registers Hide windows, which hides every window and updates the action's `selected` state. `examples/desktop/save-menu.luau` registers Save arrangement and Restore arrangement. [Bindings, menu actions, and layouts](../dev/lua-api.md#bindings-menu-actions-and-layouts) specifies the broker.

`panel:setHidden(context, true)` hides a panel while the plugin holds the returned effect. A hidden panel is not drawn or pointed at and keeps its place. When several plugins hide or show one panel, the most recent override still held decides.

A key binding is an optional chord registered with `lunette/bindings`, for input beyond the session controls. The bindings provider sees each key press before `desktop/input` delivers it to a window, so a bound key never reaches a window. The modifiers are `control`, `alt`, `logo`, and `shift`, and a chord matches only with exactly those held. Binding a chord that is already bound raises an error. The binding ends with the plugin.

## Decorations

`desktop/decorations` gives native panels the shared UI titlebar, which carries the title, a close button, and the monitor controls, and moves its panel when dragged. Its `style` is the `desktop/decorations` setting:

```luau
settings = {
  ['desktop/decorations'] = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
},
```

Other decorations are a plugin that does what `lua/lunette-plugins/desktop/decorations/init.luau` does. It creates a titlebar for each panel in `panels:all()` with `ui:newTitlebar(owner, { name, target, visible?, ...options })` and destroys it from `panels:onRemoved`. Disabling `desktop/decorations` and inserting such a plugin replaces it. [Joined frame attachments](../dev/lua-api.md#joined-frame-attachments) specifies how a titlebar joins its target's outline.

## Tags and workspaces

A tag is a named group of panels. Rules name a window's tags, `desktop/workspaces` puts a window in no workspace into the selected one, and `desktop/arrange` arranges each tag. A plugin that needs a tag holds it, which creates it if no plugin has, so start order does not matter:

```luau
local web = tagService:hold(context, { name = 'web' })
```

The tag lasts while any plugin holds it. A plugin moves a window that another plugin put in a tag by excluding it there and adding it elsewhere, and the window returns when the plugin deactivates:

```luau
main:exclude(context, panel)
web:add(context, panel)
```

`tags:onChanged(context, { run = function(change) end })` reports tags created and destroyed and changes to their selection and members; `change.kind` names the change and `change.tag` the tag. `web:setSelected(context, true)` returns an effect that selects the tag until it is disposed or the plugin deactivates.

`desktop/workspaces` shows one workspace's windows at a time. The `desktop/workspaces` setting lists the workspaces, and with more than one the consumer registers a menu action for each. [Workspaces](desktop-configuration.md#workspaces) describes the setting. A workspace consumer of another kind listens to `onChanged` and hides panels with `setHidden` in the same way. The [workspace policy](../../lua/lunette-plugins/desktop/workspaces/docs/workspace-policy.md) describes the shipped consumer's selection and placement behavior.

## Rules

`desktop/rules` takes the rule list. A rule matches window fields such as `appId` or `title`, or `where`, a predicate over the whole window, and its properties say where the window goes and how big it is. `examples/desktop/main.luau` sizes picture-in-picture windows by title:

```luau
settings = {
  ['desktop/rules'] = {
    rules = {
      {
        match = {
          where = function(window): boolean
            return type(window.title) == 'string' and window.title:lower():find('picture', 1, true) ~= nil
          end,
        },
        properties = { width = 0.6, priority = 20 },
      },
    },
  },
},
```

`hidden = true` places a window hidden, `adopt = false` leaves it out of the desktop, and `tags` names the tags it joins. A property the desktop does not recognise reaches the panel only through the placement provider's `panelOptions` hook, as [Rules and placement](../dev/lua-api.md#rules-and-placement) shows. A plugin that resolves properties from elsewhere registers a source with `rules:addSource` at a precedence relative to `require('@lunette-contracts/vocabulary').PRECEDENCE`; a source above `PRECEDENCE.persisted` overrides the saved arrangement.

## Presenting errors

Plugins receive errors through the `lunette/errors` stream, which suppresses repeats. `desktop/errors` draws the latest report over the scene. `examples/desktop/notify-errors.luau` also sends each report as a desktop notification:

```luau
stream:onReport(context, {
  run = function(report: errors.Report)
    if failed then
      return
    end
    local summary = report.message:match '^[^\n]*' or report.message
    lunette.spawn { argv = { settings.program, '--app-name=lunette', 'lunette error', summary } }
  end,
})
```

`errors:latest()` returns the most recent report, so a presenter that starts late can show it.

## Saving the arrangement

The desktop saves window positions when a window is dropped and at quit. A window is identified across sessions by its application id. `desktop/persistence` takes the file name:

```luau
settings = {
  ['desktop/persistence'] = { file = 'example.state' },
},
```

It also provides `lunette/arrangement`, whose `save` and `restore` methods `examples/desktop/save-menu.luau` calls. A file that cannot be read, or that a newer version wrote, is not overwritten; [persistence behavior](../../lua/lunette-plugins/arrangement/docs/persistence.md) specifies the file rules, and [placement](../dev/standard-plugins.md#placement) describes its role in the default composition.

## Frame rates and sharpness

`desktop/pacing` lowers the frame rate of a hidden panel's window unless its content type is exempt, and `desktop/scale` raises an output's scale in steps as the head approaches its nearest panel. The `pacing` and `scale` providers hold the tuning:

```luau
settings = {
  pacing = { tuning = { background = 5, exemptTypes = { photo = true } } },
  scale = { tuning = { reference = 0.8 } },
},
```

A replacement rule is a plugin that provides `lunette/pacing` or `lunette/scale` in the provider's entry. A different policy, such as pacing by gaze, is a consumer in place of `desktop/pacing`. Disabling `desktop/pacing` or `desktop/scale` leaves every client at its own rate or scale. [Pacing policy](../../lua/lunette-plugins/desktop/pacing/docs/pacing-policy.md) and [output-scale policy](../../lua/lunette-plugins/desktop/scale/docs/output-scale-policy.md) specify the shipped consumers. [Frame pacing and output scale](../dev/lua-api.md#frame-pacing-and-output-scale) states the shared contract.

## Checking a configuration

`lunette check` typechecks every `.luau` file in the configuration directory, and every module they require, in strict mode against the runtime's definitions. Naming files or directories, as in `lunette check main.luau`, checks those instead. The checker reports type errors, accidental globals, locals used before their declaration, and capabilities with no service type. It does not run descriptors or initializers. Invalid settings and patches raise an error when the configuration loads, an invalid entry configuration stops startup before any plugin activates, and an initializer error fails only that plugin's activation.

## Decisions

Consumers import neutral service contracts instead of provider implementations. The independent audio example uses the same public services as the backdrop, because PCM and feature consumption must remain available without a visual effect. Owner-scoped readers make plugin interruption and recovery release only that consumer's resources.

Development diagnostics stay opt-in and outside installed roots. Enabling capture merely to inspect an unused provider was rejected because requiring the development configuration must not add an unexpected reader. Diagnostics use public metadata and no renderer so a GPU, headset, or private production method is unnecessary.

## Known gaps

A static check verifies declared shapes, not plugin-graph wiring or live host behaviour. Local tests cover the real Lua providers over deterministic fake capture. Live PipeWire graph and headset acceptance remain [pending](../dev/audio.md#acceptance).

## Deliberately left open

Beat and tempo tracking, microphone input, persistent process-source preferences, and spatial playback routing are outside the audio-consumer contracts.
