# Writing plugins

A lunette configuration is a LÖVR project whose `main.luau` composes the shipped desktop and adds or replaces plugins in it. A plugin is a definition: a name, the contracts it requires and provides, and an initializer that runs when the plugin loads. Everything a plugin creates while it loads is undone when it unloads.

The code in this guide is in four example configurations, `examples/first-plugin`, `examples/keyboard`, `examples/layout`, and `examples/desktop`. `make check` typechecks all four and runs them in the desktop test harness, so the code here is code that works. [The Lua API](../dev/lua-api.md#plugin-authoring) is the specification this guide follows.

## A configuration to work in

`lunette --dump-config` writes `main.luau` and `conf.luau` to `$XDG_CONFIG_HOME/lunette`, or to a directory given after the flag, together with a `.luaurc` that names the Lua roots by absolute path. The `.luaurc` is what lets `lunette check` and an editor resolve `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`. A configuration copied by hand from the source tree carries a `.luaurc` whose relative paths point nowhere. From a source tree that is not installed, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` writes one that names the tree's roots.

The shipped `main.luau` is one call:

```lua
require('@lunette-desktop').run()
```

`run` takes `patches`, which change the desktop's list of plugins. `require('@lunette-desktop').entries()` answers that list; each entry has an `id`, such as `keyboard`, `laser`, or `desktop/keyboard`. The built-in plugins provide services, such as panels, pointers, and the keyboard, and the `desktop/` entries use them: `desktop/render` draws the panels, `desktop/decorations` gives them title bars, `desktop/pointing` points the lasers, and so on. Every one of them is a module under `@lunette-plugins`, a built-in provider under its id and a `desktop/` entry under `@lunette-plugins/desktop/`, so the code behind `desktop/keyboard` is `@lunette-plugins/desktop/keyboard`.

Plugin modules go in the configuration directory and are required with a relative path such as `require './hello'`. A relative path starts from the directory that holds the requiring module, in a session and in `lunette check` alike, so a plugin split across `myplugin/init.luau` and `myplugin/draw.luau` requires its part as `require '@self/draw'`: an `init.luau` is the module its directory names, so `./draw` from it would be a sibling of the directory. A relative path cannot climb out of the configuration directory. [Module roots](../dev/stdlib.md#module-roots) states the full rules.

## A first plugin

`examples/first-plugin/hello.luau` draws a line of text over the scene:

```lua
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'

return plugin.define {
  name = 'hello',
  requires = { frame = frame.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local frames: frame.Service = context:require(frame.capability)
    local pose = lovr.math.newMat4():translate(0, 1.6, -1.5):scale(0.1)
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        pass:text('hello from a plugin', pose)
      end,
    })
  end,
}
```

`plugin.define` takes named fields. `requires` names the contracts the plugin uses, here the frame contract, which delivers LÖVR's update, draw, key, text, and quit callbacks to plugins. `init` receives a context, the plugin's configuration, and a publisher. `context:require` answers the service behind a required contract. `frames:onDraw` registers a draw handler for the plugin: the first argument is the owner, and the context is the owner. The `overlay` phase draws over everything else; the other phases are `input`, `scene`, and `pointing`.

The plugin goes into the desktop as an inserted entry:

```lua
require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'hello', definition = require './hello' } },
  },
}
```

## Contracts and capabilities

A contract is a module that declares a capability and the type of the service behind it. `examples/first-plugin/clock.luau` is one:

```lua
local plugin = require '@lunette-plugin'

local clock = {}

export type Service = {
  read now: (Service) -> number,
  read elapsed: (Service) -> number,
}

clock.capability = plugin.capability<<Service>> { name = 'example/clock', schema = 1 }

return clock
```

`plugin.capability<<Service>>` names the service type, so `context:require(clock.capability)` answers a `clock.Service` and the checker reads every use of it. A capability declared without `<<Service>>` has an unknown service type, and `lunette check` reports it. The name is qualified by an authority, here `example`, and the schema is a positive integer that a provider and its consumers must agree on.

A plugin that requires a contract loads only while some plugin provides it. When the provider unloads, every plugin that requires it unloads first, and loads again when a provider returns. A plugin therefore needs no code for a missing service.

## Providing a service

`examples/first-plugin/clock-provider.luau` declares an empty schema and builds the published service from resolved settings:

```luau
local plugin = require '@lunette-plugin'
local clock = require './clock'
local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.provider<<Config, Settings, clock.Service>>({
  name = 'clock',
  capability = clock.capability,
  schema = descriptor,
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
}).definition
```

`publish:provide` is valid only during `init`. A consumer receives a read-only view of the table, and a method called through the view after the provider has unloaded raises an error naming the contract. Two loaded plugins cannot provide the same contract at the same time.

## Effects, ownership, and options

`examples/first-plugin/uptime.luau` declares its options with a descriptor, counts opened windows, and draws the elapsed time:

```luau
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local clock = require './clock'
local schema = require '@lunette-plugin/schema'

local descriptor = schema.object { prefix = schema.default(schema.string()) 'up' }
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>>({
  name = 'uptime',
  requires = { frame = frame.capability, clock = clock.capability },
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
    local pose = lovr.math.newMat4():translate(0, 1.4, -1.5):scale(0.05)
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        pass:text(string.format('%s %.0fs, %d windows', settings.prefix, time:elapsed(), opened), pose)
      end,
    })
  end,
}).definition
```

A plugin changes state outside itself only through its context. `context:on` subscribes to a native event for as long as the plugin is loaded. `context:effect` registers any other resource with the function that releases it. A service method that takes an owner, such as `frames:onDraw(context, ...)` or `keyboard:new(context)`, ties what it creates to that owner, and the provider releases it when the owner unloads. A direct `lunette.onWindowOpened(handler)` call in `init` is not tracked: the subscription outlives the plugin, and a reloaded plugin subscribes a second time.

`plugin.consumer<<Config, Settings>>` takes `name`, `requires`, `schema`, `defaults`, `validate`, and `init`. `requires` and `validate` are optional. A schema and legacy defaults cannot both be supplied. `Config` describes the caller's overrides. `Settings` describes the resolved settings passed to `init(context, settings)`. The context remains a `plugin.Context`; each service is read with `context:require(capability)` after its capability is declared in `requires`.

Schema-backed modules derive both types from the descriptor. The constructors are available through `require '@lunette-plugin/schema'` and `plugin.schema`. The checked uptime consumer above shows the complete pattern and returns the configured definition with `.definition`.

The helper parses an empty configuration when it constructs a configured definition. Every required field therefore needs a schema default or an optional descriptor, and invalid defaults raise before the definition is returned. That check does not run the plugin initializer. The desktop's `compose` parses desktop settings and expands them into entry patches before activation. `management.start` resolves every managed entry configuration before activating any instance, so a preflight error aborts startup. In contrast, `plugin.start` and direct native runtime use validate an entry's configuration as that instance activates; a validation or initializer error fails that instance without aborting other entries. [Configuration schemas](configuration-schema.md) describes the constructors, merge rules, type derivation, and checker limitations. `plugin.provider<<Config, Settings, Service>>` accepts the same schema and passes resolved settings to `build(context, settings)`.

The helper returns `definition`, `define`, and `requires`. `definition` uses the resolved initial settings. `define { name = 'other-uptime', prefix = 'running for' }` creates a definition with different defaults and an optional name. Runtime configuration resolves over those bound defaults. Schema objects merge declared fields recursively; arrays and maps replace their bound values. Settings and plain configuration containers are copied and frozen according to the descriptor. Callbacks and custom values retain their exact references, and native vectors retain their values. Constructing the helper or calling `define` does not call `init` or acquire resources. State declared inside `init` is local to that activation and is recreated when the plugin activates again. An entry's `factory` can enclose state shared by that runtime's activations; `plugin.start` calls each entry's factory once.

`plugin.definitionSchema(definition)` and `definition.schema` expose the immutable schema metadata. Its root is a default descriptor whose `child` is the supplied descriptor and whose `value` is that definition's resolved defaults. `definition.resolve(config)` validates an unknown configuration against those bound defaults without constructing a plugin. It also runs `validate(settings, name)` when supplied. Low-level `plugin.define` retains its raw configuration initializer and does not attach schema metadata.

Legacy modules may still supply `defaults`, or omit both `defaults` and `schema` when they take no options. They use the option resolution of `plugin.options`, which rejects unknown options and values whose types differ from their defaults. Legacy definitions have a preflight resolver but no schema metadata. For both authoring forms, `validate(settings, name)` runs for the initial settings, for `define` overrides, for preflight resolution, and for runtime configuration. Schema-backed validation runs after the descriptor's constraints and refinements. Validation must not acquire resources or change external state. With `plugin.start` or direct native runtime activation, a runtime validation error fails that instance and is reported while other entries continue. Managed startup validates all entry configurations before activation and aborts on a preflight error. A patch gives the configuration:

```lua
{ insert = { id = 'uptime', definition = require './uptime', config = { prefix = 'running for' } } },
```

Geometric positions, directions, and offsets are native `vector` values, constructed with `vector.pack(x, y, z)`. Config and Settings fields name `vector` directly. `plugin.checkVector(name, option, value)` rejects non-finite components. Vectors are immutable, so `direction = direction:normalize()` uses the returned value. `Mat4:translate(vector)` accepts a vector directly. Colours, two-dimensional coordinates, lists, and full matrices retain their distinct representations.

`examples/first-plugin/main.luau` inserts all three plugins.

## Configuring a built-in plugin

[Desktop configuration](desktop-configuration.md) describes the typed consumer settings, workspace configuration, and entry-specific patches. Raw patches retain access to every plugin replacement and insertion.

A patch with an entry's `id` changes that entry. A schema-backed definition resolves `config` through its descriptor: declared objects merge key by key, while arrays, maps, unions, and atomic values replace. Raw and legacy definitions retain recursive string-keyed table merging. `disabled = true` removes the entry, and `definition` replaces what the entry is made from. An unknown id raises when the configuration loads.

`desktop.configure` takes a plugin's definition and answers a function that makes a configuration patch for the entry named by the definition's name, typed with that definition's options, so the checker reads them. A built-in provider's module holds its definition as `definition`; a desktop consumer's module is its definition, or for `desktop/arrange` a factory of it, which `configure` takes as well. `desktop/persistence` is `@lunette-plugins/arrangement`, which holds its factory as `factory` beside its format functions:

```lua
local desktop = require '@lunette-desktop'
local laser = require '@lunette-plugins/laser'

desktop.run {
  patches = {
    desktop.configure(laser.definition) { style = { color = { 1, 0.4, 0.2, 0.6 } } },
    desktop.configure(require '@lunette-plugins/desktop/keyboard') { hand = 'right', placement = { distance = 0.45 } },
  },
}
```

`desktop.configure(require '@lunette-plugins/desktop/keyboard') { hand = 'rigth' }` is a type error, where `{ id = 'desktop/keyboard', config = { hand = 'rigth' } }` passes `lunette check`: a patch list mixes entries, so a plain patch's `config` has no type of its own. A misspelt key is not a type error in Luau either way. Runtime validation rejects it during configuration resolution, with an error naming its path. Each built-in provider's options are listed in [the standard library](../dev/stdlib.md#contracts-and-providers) and, for the keyboard, in [Keyboard](../dev/lua-api.md#keyboard).

## Extending the built-in keyboard

Each built-in provider module answers `definition`, the definition the desktop uses; `define`, which makes another definition with other defaults; `build`; and `requires`. `define` is typed, so the checker reads its options. `examples/keyboard/split.luau` is the built-in keyboard with other rows, a numpad layer, a click on every key, and a flash on the key that was pressed.

Rows are lists of keys. A key has an evdev `code` or an `action`; a key with neither is a spacer. `width` and `height` are in key units, and `x` is room left before the key. Codes come from `@lunette-contracts/keys`. Legends and local virtual translation use the same live keymap seat selected by the focus source. Stateless translation does not implement dead-key composition. Physical committed text remains separate from virtual key activations.

```lua
local keyboard = require '@lunette-plugins/keyboard'
local keys = require '@lunette-contracts/keys'

local codes = keys.CODES
local SPLIT = 1.5

local letters: { keyboard.KeyRow } = {
  {
    { code = codes.q },
    -- ...
    { code = codes.t },
    { code = codes.y, x = SPLIT },
    -- ...
  },
  {
    { action = { kind = 'layer', layer = 'numpad' }, label = '123' },
    { code = codes.space, label = 'space', width = 3 },
    { code = codes.space, label = 'space', width = 3, x = SPLIT },
    { action = { kind = 'chord', code = codes.t, modifiers = { 'control', 'alt' } }, label = 'term' },
    { action = { kind = 'hide' } },
  },
}
```

The `: { keyboard.KeyRow }` annotation matters. The checker reads an annotated table against the key type; a table in an unannotated local is only checked at runtime. `define` checks the rows at runtime as well and raises an error that names the key by its path, such as `option rows[1][1] has an unknown field widht`.

The numpad is a second set of rows, given as a layer. Its `+` key is two rows tall, and the row below leaves a spacer where the key reaches:

```lua
local numpad: { keyboard.KeyRow } = {
  { { code = codes.digit7 }, { code = codes.digit8 }, { code = codes.digit9 }, { code = codes.minus } },
  { { code = codes.digit4 }, { code = codes.digit5 }, { code = codes.digit6 }, { action = { kind = 'text', text = '+' }, height = 2 } },
  { { code = codes.digit1 }, { code = codes.digit2 }, { code = codes.digit3 }, { width = 1 } },
  { { code = codes.digit0, width = 2 }, { code = codes.dot }, { code = codes.enter, label = 'ent' } },
  { { action = { kind = 'layer', layer = 'base' }, label = 'abc', width = 4 } },
}
```

The hooks change behaviour without copying it. A hook receives its arguments and then the default, and calls the default to keep it. `onKey` runs for every key a pointer presses. `drawKey` runs for every key the keyboard draws.

```lua
local drawing = require '@lunette-plugins/keyboard/draw'

local FLASH = 0.15
local pressedAt: { [keyboard.Key]: number } = setmetatable({}, { __mode = 'k' })

return keyboard.define {
  name = 'split-keyboard',
  rows = letters,
  layers = { numpad = numpad },
  style = { keyUnit = 0.03 },
  onKey = function(board, key, pointer, base)
    pointer:vibrate { strength = 0.2, duration = 0.01 }
    pressedAt[key.source] = lovr.timer.getTime()
    base(board, key, pointer)
  end,
  drawKey = function(pass, key, state, base)
    local pressed = pressedAt[key.source]
    if pressed and lovr.timer.getTime() - pressed < FLASH then
      -- Draw a lit face, then the default legend.
      drawing.legend(pass, key, state)
      return
    end
    base(pass, key, state)
  end,
}
```

`pointer:vibrate` pulses the controller of the hand that pressed the key; the laser gives each pointer its controller. `key.source` is the row entry the key was made from, which stays the same table from frame to frame, so it can key a table across frames. `drawing` is `@lunette-plugins/keyboard/draw`, which has the default drawing's halves, `face` and `legend`, and `faceColor`. `examples/keyboard/rounded.luau` uses them to draw rounded faces and keep the default legends.

The definition replaces the desktop's keyboard by id:

```lua
{ id = 'keyboard', definition = require './split' },
```

Every plugin that requires the keyboard contract, the wrist button included, then gets the split keyboard. `examples/keyboard/main.luau` does this and moves the wrist button to the right hand.

## Replacing the keyboard

A plugin that provides `lunette/keyboard` at schema 2 can take the keyboard entry's place in the same way. `service:new(owner, options)` answers a keyboard, which is a surface with `pose`, `width`, `height`, `visible`, `setPose`, `setSize`, `setVisible`, `pressKey`, `typeText`, `modifiers`, `draw`, and `destroy`. `service:inspect()` returns callback-free registration metadata. A replacement uses focus sources for routed input, clears latches and locks on route changes and hide, and implements `Options.onVisibilityChanged` after changing state. Its reasons are `show`, `hide`, `user-hide`, and `destroy`. The native-only `Options.target` callback remains subordinate to a focused local receiver. [Keyboard](../dev/lua-api.md#keyboard) and [Focus](../dev/lua-api.md#focus) specify these rules. `examples/keyboard/tiny.luau` implements the contract with one row of three keys. Its `new` ties each keyboard to the caller.

The implementation acquires the board through `context:resource(owner, acquire)`. Inside that acquisition, it creates a virtual focus source with the provider's context as the source owner, then returns the board and an inverse that releases the board and source. It releases partial acquisitions if board construction raises. The complete callback and cleanup wiring remains in `examples/keyboard/tiny.luau`.

`context:resource` checks that the owner is a live dependent plugin and registers the release with the owner, so a keyboard ends with the plugin that asked for it. It returns the acquired value and its effect only after registration succeeds. An initializer can use its own context as the owner. Cancellation releases the value and raises without returning it. An acquisition that raises before returning its inverse must clean up its partial resources. Each owner draws and offers its own keyboards. A provider can retain registration metadata for inspection without drawing another owner's keyboard or invoking target callbacks. A surface callback that answers a ray hit, `raycast`, is annotated `(number?, number?, number?)` when it is written as a method or a local function. Luau gives a function with no expected type the return type of its first `return`, so an unannotated `raycast` that misses with `return nil, nil, nil` before it returns the hit is rejected at the hit. A `raycast` written inside a table that is annotated as the surface type takes its type from the contract and needs no annotation.

## Local VR controls

The [UI guide](ui.md) describes owner-scoped flat VR panels, buttons, single-line text fields, choices, lists, and regions through the neutral `lunette/ui` contract. Its small strict fixture uses only public contracts. It records logical geometry, focus routing, themes, draw-hook safety, grapheme selection, and provider replacement tokens. The shipped wrist menu and its session actions are implemented. A checked `examples/ui` configuration remains pending. The runtime manager migration, including its search and configuration workflows, also remains pending.

## A custom layout

Windows that no rule or saved arrangement places are arranged by the `desktop/arrange` entry, with a layout it names. A layout is a function that poses a list of panels, registered by name with the layouts broker, `lunette/layouts`. The desktop registers the arc layout as `arc`, and a configuration adds another by inserting a plugin that registers it. `examples/layout/grid.luau` declares `columns`, `gap`, and a vector `center` in a schema, derives its input and output types, and registers a read-only panel callback:

```luau
local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  columns = schema.default(schema.number { minimum = 0, integer = true })(0),
  gap = schema.default(schema.number())(0.08),
  center = schema.default(schema.vector())(vector.pack(0, 1.5, -1.8)),
}
export type Config = schema.Input<typeof(descriptor)>
export type Options = schema.Output<typeof(descriptor)>
local optionsSchema = schema.default(descriptor)(descriptor.parse {})

local function resolve(given: unknown): Options
  return optionsSchema.parse(given, 'grid')
end

local function grid(panels: { read [number]: layouts.Panel }, given: unknown?): ()
  local options = resolve(given)
  local count = #panels
  if count == 0 then
    return
  end
  local columns = if options.columns > 0 then options.columns else math.ceil(math.sqrt(count))
  local rows = math.ceil(count / columns)
  local cellWidth, cellHeight = 0, 0
  for index = 1, count do
    local panel = panels[index]
    cellWidth = math.max(cellWidth, panel.width or 0)
    cellHeight = math.max(cellHeight, panel.height or 0)
  end
  cellWidth += options.gap
  cellHeight += options.gap
  local center = options.center
  for index = 1, count do
    local panel = panels[index]
    local column = (index - 1) % columns
    local row = (index - 1) // columns
    local offset = vector.pack((column - (columns - 1) / 2) * cellWidth, ((rows - 1) / 2 - row) * cellHeight, 0)
    panel:setPose(lovr.math.newMat4():translate(center + offset))
  end
end

local consumerSchema = schema.object {}
type ConsumerConfig = schema.Input<typeof(consumerSchema)>
type ConsumerSettings = schema.Output<typeof(consumerSchema)>

return plugin.consumer<<ConsumerConfig, ConsumerSettings>>({
  name = 'grid-layout',
  requires = { layouts = layouts.capability },
  schema = consumerSchema,
  init = function(context: plugin.Context, _settings: ConsumerSettings)
    local service: layouts.Service = context:require(layouts.capability)
    service:register(context, { name = 'grid', apply = grid })
  end,
}).definition
```

The layout receives a read-only list of live panels and the caller's options. It decides nothing about which panels it gets: `desktop/arrange` passes adopted windows of the workspace tag that were placed without a pose, less any the user has since dragged. The grid's `resolve` function parses options against its descriptor, so a misspelt or mistyped option raises an error naming its path. The registration is owned by the plugin's context, so it ends when the plugin unloads, and a second registration of the same name raises.

Two patches add the grid and choose it:

```lua
{ insert = { id = 'grid-layout', definition = require './grid' } },
desktop.configure(require '@lunette-plugins/desktop/arrange') {
  layout = 'grid',
  options = { grid = { columns = 3 } },
},
```

`options` gives each layout its options by name, and `desktop/arrange` passes a layout its own whichever tag uses it, so a tag that chooses `grid` with `tag:setLayout` is laid out in three columns too. An inserted entry is enabled after the shipped ones, so the grid registers after `desktop/arrange` has started, and `desktop/arrange` arranges again when it does. If no layout of the chosen name has registered by the first frame, `desktop/arrange` logs a warning naming it.

A layout registered with `continuous = true` is applied on every frame as well. `examples/layout/follow.luau` is one: it keeps the windows on an arc around the head and swings the arc round once the head has turned far enough away from it. It reuses the arc layout's geometry, `@lunette-plugins/layout/arc/geometry`, which spaces panels by their widths so that wide ones do not overlap. `examples/layout/main.luau` inserts both layouts and chooses the grid; `layout = 'follow'` chooses the other.

To replace the built-in arc rather than add beside it, disable the `layout/arc` entry and register another layout as `arc`. A layout is never overridden in place.

## Changing how pointers behave

The interaction provider turns each frame of a laser's input into hovering, clicking, scrolling, and carrying. It has two hooks. `constrain(surface, pose, base)` answers where a carried surface goes for where the hand would put it, so a rule about how panels move is one function. `examples/desktop/upright.luau` keeps carried panels level:

```lua
local interaction = require '@lunette-plugins/interaction'
local surface = require '@lunette-contracts/surface'

return function(target: surface.Surface, pose: Mat4, base: interaction.ConstrainBase): Mat4
  local kept = base(target, pose)
  local x, y, z = kept:getPosition()
  local forwardX, _, forwardZ = kept:mul(0, 0, -1, 0)
  local yaw = math.atan2(-forwardX, -forwardZ)
  return lovr.math.newMat4():translate(x, y, z):rotate(yaw, 0, 1, 0)
end
```

A hook is an option, so a patch gives it:

```lua
desktop.configure(require('@lunette-plugins/interaction').definition) { constrain = require './upright' },
```

`drive(pointer, input, surfaces, base)` runs for every frame of every pointer, and `base` is the default mapping: grip to grab, buttons to click, the stick to scroll or push. A hook that calls `base` with changed input remaps it, and one that does not call `base` drives the pointer's primitives, `hover`, `setButton`, `beginGrab`, `dragTo`, and `endGrab`, itself. `@lunette-plugins/interaction/picking` has the default's picking and scrolling for such a hook. `focusOnPress = false` stops a click from giving the keyboard to what it clicks.

Which controller button presses which pointer button is the laser's `buttons` option, a list that replaces the default:

```lua
desktop.configure(require('@lunette-plugins/laser').definition) {
  buttons = {
    { control = 'trigger', button = 'left' },
    { control = 'a', button = 'right' },
  },
},
```

A plugin that moves surfaces for a pointer, as a replacement interaction would, announces each drop through `lunette/drops`. The desktop remembers a dropped window's place, saves the arrangement, and keeps a dropped window out of the automatic arrangement only because it hears those drops.

## Key bindings

A key binding is an optional chord registered with `lunette/bindings`. The bindings provider takes every key press before `desktop/input` sends keys to a window, so a bound key never reaches one; while the provider is unavailable, keys still reach windows. The shipped desktop uses menu actions for session controls. The following plugin shows a custom key binding that hides windows:

```lua
return plugin.define {
  name = 'hide-windows',
  requires = { bindings = bindings.capability, panels = panels.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local keys: bindings.Service = context:require(bindings.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local overrides: { plugin.Effect } = {}
    keys:register(context, {
      chord = { key = 'h', modifiers = { 'control', 'alt' } },
      run = function(_press: bindings.Press)
        if #overrides > 0 then
          for _, override in ipairs(overrides) do
            override:dispose()
          end
          table.clear(overrides)
          return
        end
        for _, panel in ipairs(panelService:all()) do
          if panel.kind == 'window' then
            overrides[#overrides + 1] = panel:setHidden(context, { hidden = true })
          end
        end
      end,
    })
  end,
}
```

The modifiers are `control`, `alt`, `logo`, and `shift`, and a chord matches only with exactly those held. A chord is bound once: binding one that is bound raises, so two plugins cannot both take a key. The binding ends when the plugin unloads.

`panel:setHidden(context, { hidden = true })` hides a panel for as long as the plugin holds the returned effect. A hidden panel is not drawn and cannot be pointed at; it keeps its place. Several plugins can hide or show one panel, and the most recent one still holding an override decides, so disposing this plugin's overrides shows only what it hid.

The shipped desktop registers configuration reload as the `desktop/reload` menu action in `desktop/actions`. The wrist menu displays it. A configuration can register additional actions through `lunette/menu`, as [Menu actions](../dev/lua-api.md#menu-actions) specifies.

## Decorations

Panels draw no frame of their own. The `desktop/decorations` entry draws a border round each panel and a title bar above it, and grabbing the bar moves the panel. Its `style` is configuration, as in `examples/desktop/main.luau`:

```lua
desktop.configure(require '@lunette-plugins/desktop/decorations') { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
```

Decorations of another kind are a plugin that does what `lua/lunette-plugins/desktop/decorations/init.luau` does: it hears panels arrive and leave through `panels:onAdded` and `panels:onRemoved`, draws in the frame's `scene` phase, and offers its bars with `surfaces:offer`. A bar is a surface whose `setPose` moves its panel, and it carries the panel's `kind` and `source`, so dropping it counts as dropping the panel. Disabling `desktop/decorations` and inserting such a plugin replaces it.

## Tags and workspaces

A tag is a named group of panels. Adoption puts every window in `main` unless a rule names other tags, and `desktop/arrange` arranges each tag. A plugin that needs a tag holds it, which makes it if nobody has, so it does not matter which plugin starts first:

```lua
local tag = tagService:hold(context, { name = 'web' })
```

The tag lasts while any plugin holds it. A plugin moves a window that another plugin put in a tag by excluding it there and adding it elsewhere, and the window goes back when the plugin unloads:

```lua
main:exclude(context, { panel = panel })
web:add(context, panel)
```

`tags:onChanged(context, { run = function(change) end })` hears tags being made and ending and their selection, layout, and members changing; `change.kind` says which and `change.tag` which tag. A tag's layout is the name of a registered layout, which `desktop/arrange` uses for that tag instead of its own:

```lua
web:setLayout(context, { layout = 'grid' })
```

The shipped `desktop/workspaces` consumer shows one workspace's windows at a time and hides the rest. It is not in the default desktop; `examples/desktop/main.luau` inserts it with two workspaces. The consumer registers a menu action for each workspace; workspace selection does not require a key chord:

```lua
{
  insert = {
    id = 'desktop/workspaces',
    definition = require '@lunette-plugins/desktop/workspaces',
    config = {
      workspaces = { { name = 'main' }, { name = 'side' } },
    },
  },
},
```

A window that opens goes to the workspace in view. A workspace consumer of another kind, such as one switched by a gesture, listens to `onChanged` and hides panels with `setHidden` the same way.

## Rules

`desktop/rules` takes the rule list. A rule matches named fields of a window, such as `appId` or `title`, or `where`, a function of the whole window, and its properties say where the window goes and how big it is. `examples/desktop/main.luau` sizes picture-in-picture windows by their title:

```lua
desktop.configure(require '@lunette-plugins/desktop/rules') {
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
```

A rule's `hidden = true` places a window hidden, `adopt = false` leaves it out of the desktop altogether, and `tags` names the tags it joins. A property the desktop does not know reaches the panel only through a custom placement: `placement.define { panelOptions = function(properties, window, base) ... end }` receives the resolved properties and the default mapping, as [Rules and placement](../dev/lua-api.md#rules-and-placement) shows. A plugin that resolves properties from somewhere else, such as a file, registers a source with `rules:addSource`, at a precedence named relative to `require('@lunette-contracts/vocabulary').PRECEDENCE`; a source above `PRECEDENCE.persisted` overrides the saved arrangement.

## Presenting errors

Errors reach plugins through the `lunette/errors` stream, which has already dropped repeats. The shipped `desktop/errors` draws the latest one over the scene; its position, size, and colour are its configuration. Any plugin can present them as well. `examples/desktop/notify-errors.luau` sends each as a desktop notification:

```lua
stream:subscribe(context, {
  run = function(report: errors.Report)
    if failed then
      return
    end
    local summary = report.message:match '^[^\n]*' or report.message
    lunette.spawn { argv = { settings.program, '--app-name=lunette', 'lunette error', summary } }
  end,
})
```

`errors:recent()` answers the reports kept so far, so a presenter that starts late can show what it missed, and `errors:clear(context)` dismisses them for every presenter. Disabling `desktop/errors` leaves the custom presenter as the only one.

## Saving the arrangement

The desktop saves where the windows are whenever one is dropped, and at quit. `desktop/persistence`, whose module is `@lunette-plugins/arrangement`, takes the file it saves to, the format it writes, and `keyFor`, which says what identifies a window across sessions, by default its application id:

```lua
desktop.configure(require('@lunette-plugins/arrangement').factory) { file = 'example.state' },
```

It also provides `lunette/arrangement`, so a plugin can save or restore windows. `examples/desktop/save-menu.luau` registers Save arrangement and Restore arrangement actions. `examples/desktop/hide-windows.luau` registers an action that toggles owner-scoped visibility overrides for windows. `examples/desktop/main.luau` inserts both examples. [Menu actions](../dev/lua-api.md#menu-actions) specifies the action broker.

A custom format is a `{ read, render }` pair; [Default configuration](../dev/stdlib.md#default-configuration) states what `read` answers so that a file written by a newer version is left alone rather than overwritten.

## Frame rates and sharpness

The desktop includes pacing and output scaling providers. `desktop/pacing` reduces the frame rate of a hidden panel's window unless its type is exempt, and `desktop/scale` raises an output's scale as the head approaches the nearest panel, in steps, so a client re-lays out only when it crosses one. The provider rules and their tuning are configured through the `pacing` and `scale` entries:

```lua
desktop.configure(require('@lunette-plugins/pacing').definition) { tuning = { background = 5, exemptTypes = { photo = true } } },
desktop.configure(require('@lunette-plugins/scale').definition) { tuning = { reference = 0.8 } },
```

Each provider takes a hook around its rule. `choose(pacer, observation, base)` answers a window's rate, so a hook that caps visible panels at 60 Hz answers 60 when `observation.visible` is true and calls `base` otherwise; `ideal(distance, base)` answers the scale a panel at that distance wants, before the steps apply. A replacement rule is a plugin that provides `lunette/pacing` or `lunette/scale`, installed in the provider entry with `{ id = 'pacing', definition = replacement }`. A different scene policy, such as pacing by gaze direction, is a consumer in place of `desktop/pacing` that keeps the provider. `{ id = 'desktop/pacing', disabled = true }` turns pacing off, and disabling either entry leaves every rate or scale as the client started with. [Frame pacing and output scale](../dev/lua-api.md#frame-pacing-and-output-scale) states the rules.

## Checking a configuration

`lunette check` typechecks every `.lua` and `.luau` file in the configuration directory a session would load, and every module they require, in strict mode, against the runtime's definitions. Naming files or directories, as in `lunette check main.luau`, checks those instead. The checker reports type errors, an accidental global, a local used before it is declared, and a capability with an unknown service type. It checks the options of a `desktop.configure` patch but not a plain patch's `config`. The checker does not execute descriptors or plugin initializers. Invalid defaults can fail during definition construction, invalid desktop settings during composition, and invalid managed entry configuration during startup preflight. Initializer errors and configuration errors supplied directly through `plugin.start` or the native runtime fail the affected activation and are reported through the runtime error path.
