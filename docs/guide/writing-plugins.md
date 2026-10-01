# Writing plugins

A lunette configuration is a LÖVR project whose `main.lua` composes the shipped desktop and adds or replaces plugins in it. A plugin is a definition: a name, the contracts it requires and provides, and an initializer that runs when the plugin loads. Everything a plugin creates while it loads is undone when it unloads.

The code in this guide is in three example configurations, `examples/first-plugin`, `examples/keyboard`, and `examples/layout`. `make check` typechecks all three and runs them in the desktop test harness, so the code here is code that works. [The Lua API](../dev/lua-api.md#plugin-authoring) is the specification this guide follows.

## A configuration to work in

`lunette --dump-config` writes `main.lua` and `conf.lua` to `$XDG_CONFIG_HOME/lunette`, or to a directory given after the flag, together with a `.luaurc` that names the installed Lua roots by absolute path. The `.luaurc` is what lets `lunette check` and an editor resolve `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`. A configuration copied by hand from the source tree carries a `.luaurc` whose relative paths point nowhere.

The shipped `main.lua` is one call:

```lua
require('@lunette-desktop').run()
```

`run` takes `patches`, which change the desktop's list of plugins. `require('@lunette-desktop').entries()` answers that list; each entry has an `id`, such as `keyboard`, `laser`, or `desktop/keyboard`.

Plugin modules go beside `main.lua` and are required with a path such as `require './hello'`. A session resolves a relative require against the configuration directory, and the checker resolves it against the requiring file. The two agree for modules at the top level of the configuration, so a configuration keeps its modules there.

## A first plugin

`examples/first-plugin/hello.lua` draws a line of text over the scene:

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
        pass:text('hello from a plugin', pose, 0, 'center', 'middle')
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

A contract is a module that declares a capability and the type of the service behind it. `examples/first-plugin/clock.lua` is one:

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

`examples/first-plugin/clock-provider.lua` provides the clock:

```lua
return plugin.define {
  name = 'clock',
  provides = { clock = clock.capability },
  init = function(_context: plugin.Context, _config: {}, publish: plugin.Publisher)
    local started = lovr.timer.getTime()
    publish:provide(clock.capability, {
      now = function(_self: clock.Service): number
        return lovr.timer.getTime()
      end,
      elapsed = function(_self: clock.Service): number
        return lovr.timer.getTime() - started
      end,
    })
  end,
}
```

`publish:provide` is valid only during `init`. A consumer receives a read-only view of the table, and a method called through the view after the provider has unloaded raises an error naming the contract. Two loaded plugins cannot provide the same contract at the same time.

## Effects, ownership, and options

`examples/first-plugin/uptime.lua` consumes the clock, takes an option, and counts opened windows:

```lua
export type Config = { read prefix: string? }

return plugin.define {
  name = 'uptime',
  requires = { frame = frame.capability, clock = clock.capability },
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher)
    local settings = plugin.options { name = 'uptime', defaults = { prefix = 'up' }, config = config }
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
}
```

A plugin changes state outside itself only through its context. `context:on` subscribes to a native event for as long as the plugin is loaded. `context:effect` registers any other resource with the function that releases it. A service method that takes an owner, such as `frames:onDraw(context, ...)` or `keyboard:new(context)`, ties what it creates to that owner, and the provider releases it when the owner unloads. A direct `lunette.onWindowOpened(handler)` call in `init` is not tracked: the subscription outlives the plugin, and a reloaded plugin subscribes a second time.

`plugin.options` merges the configuration over the defaults and raises an error naming the plugin and the option for an option the defaults do not have, or for a value of another type than its default. The error fails that plugin's load and is reported; the rest of the desktop loads. A patch gives the configuration:

```lua
{ insert = { id = 'uptime', definition = require './uptime', config = { prefix = 'running for' } } },
```

`examples/first-plugin/main.lua` inserts all three plugins.

## Configuring a built-in plugin

A patch with an entry's `id` changes that entry. `config` merges into its configuration: a table with string keys merges key by key, and any other value, a list included, replaces the default. `disabled = true` removes the entry, and `definition` replaces what the entry is made from. An unknown id raises when the configuration loads.

```lua
require('@lunette-desktop').run {
  patches = {
    { id = 'laser', config = { style = { color = { 1, 0.4, 0.2, 0.6 } } } },
    { id = 'desktop/keyboard', config = { hand = 'right', placement = { distance = 0.45 } } },
  },
}
```

A patch's `config` is not typed, so a misspelt option passes `lunette check` and fails the entry's load with an error that names the option. Each built-in provider's options are listed in [the standard library](../dev/stdlib.md#contracts-and-providers) and, for the keyboard, in [Keyboard](../dev/lua-api.md#keyboard).

## Extending the built-in keyboard

Each built-in provider module answers `definition`, the definition the desktop uses; `define`, which makes another definition with other defaults; `build`; and `requires`. `define` is typed, so the checker reads its options. `examples/keyboard/split.lua` is the built-in keyboard with other rows, a numpad layer, a click on every key, and a flash on the key that was pressed.

Rows are lists of keys. A key has an evdev `code` or an `action`; a key with neither is a spacer. `width` and `height` are in key units, and `x` is room left before the key. Codes come from `@lunette-contracts/keys`, and legends come from the seat's keymap, so the rows work on any layout.

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

`pointer:vibrate` pulses the controller of the hand that pressed the key; the laser gives each pointer its controller. `key.source` is the row entry the key was made from, which stays the same table from frame to frame, so it can key a table across frames. `drawing` is `@lunette-plugins/keyboard/draw`, which has the default drawing's halves, `face` and `legend`, and `faceColor`. `examples/keyboard/rounded.lua` uses them to draw rounded faces and keep the default legends.

The definition replaces the desktop's keyboard by id:

```lua
{ id = 'keyboard', definition = require './split' },
```

Every plugin that requires the keyboard contract, the wrist button included, then gets the split keyboard. `examples/keyboard/main.lua` does this and moves the wrist button to the right hand.

## Replacing the keyboard

A plugin that provides `lunette/keyboard` itself can take the keyboard entry's place in the same way. The contract is small: `service:new(owner, options)` answers a keyboard, which is a surface with `pose`, `width`, `height`, `visible`, `setPose`, `setSize`, `setVisible`, `pressKey`, `typeText`, `modifiers`, `draw`, and `destroy`. `examples/keyboard/tiny.lua` implements it with one row of three keys. Its `new` ties each keyboard to the caller:

```lua
new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
  local made: keyboard.Keyboard? = nil
  context:acquire(owner, function()
    local board = make(focus, options)
    made = board
    return function()
      board:destroy()
    end
  end)
  return assert(made, 'the keyboard was acquired')
end,
```

`context:acquire` checks that the owner is a live plugin and registers the release with the owner, so a keyboard ends with the plugin that asked for it. Each owner draws and offers its own keyboards, so a provider keeps no list of them. A surface callback that answers a ray hit, `raycast`, is annotated `(number?, number?, number?)`; without the annotation the checker infers the return from the first `return nil, nil, nil` and rejects the hit.

## A custom layout

Windows that no rule or saved arrangement places are arranged by the `desktop/arrange` entry, with a layout it names. A layout is a function that poses a list of panels, registered by name with the layouts broker, `lunette/layouts`. The desktop registers the arc layout as `arc`, and a configuration adds another by inserting a plugin that registers it. `examples/layout/grid.lua` registers a grid:

```lua
local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'

local DEFAULTS = { columns = 0, gap = 0.08, center = { 0, 1.5, -1.8 } }

local function grid(panels: { layouts.Panel }, given: unknown?): ()
  local options = plugin.options { name = 'grid', defaults = DEFAULTS, config = given }
  -- Work out each panel's cell from options.columns and the largest panel.
  for index, panel in ipairs(panels) do
    layouts.setPose(panel, lovr.math.newMat4():translate(x, y, options.center[3]))
  end
end

return plugin.define {
  name = 'grid-layout',
  requires = { layouts = layouts.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local service: layouts.Service = context:require(layouts.capability)
    service:register(context, { name = 'grid', apply = grid })
  end,
}
```

The layout receives the live panels in the order the caller gives them and the caller's options. It decides nothing about which panels it gets: `desktop/arrange` passes the adopted windows of the workspace tag that were placed without a pose, less any the user has since dragged. `plugin.options` checks the options against the defaults, so a misspelt option raises an error naming it. `layouts.setPose` poses a panel; calling `panel:setPose` directly is reported by the checker as an ambiguous call, because a panel's type joins the surface's optional `setPose` with the panel's own. The registration is owned by the plugin's context, so it ends when the plugin unloads, and a second registration of the same name raises.

Two patches add the grid and choose it:

```lua
{ insert = { id = 'grid-layout', definition = require './grid' } },
{ id = 'desktop/arrange', config = { layout = 'grid', options = { columns = 3 } } },
```

`options` are the grid's own; `desktop/arrange` passes them through. An inserted entry is enabled after the shipped ones, so the grid registers after `desktop/arrange` has started, and `desktop/arrange` arranges again when it does. If no layout of the chosen name has registered by the first frame, `desktop/arrange` logs a warning naming it.

A layout registered with `continuous = true` is applied on every frame as well. `examples/layout/follow.lua` is one: it keeps the windows on an arc around the head and swings the arc round once the head has turned far enough away from it. It reuses the arc layout's geometry, `@lunette-plugins/layout/arc/geometry`, which spaces panels by their widths so that wide ones do not overlap. `examples/layout/main.lua` inserts both layouts and chooses the grid; `layout = 'follow'` chooses the other.

To replace the built-in arc rather than add beside it, disable the `layout/arc` entry and register another layout as `arc`. A layout is never overridden in place.

## Checking a configuration

`lunette check main.lua` typechecks `main.lua` and every module it requires, in strict mode, against the runtime's definitions. A module that nothing requires, such as `rounded.lua` in the keyboard example, is checked by naming it too. The checker reports type errors, an accidental global, a local used before it is declared, and a capability with an unknown service type. It does not check a patch's `config`, and it does not run the plugins: an option error, a malformed row, or an error raised in `init` appears when the session loads the plugin, in the log and in the error display, naming the plugin.

`pass:text(text, transform)` with only a transform is reported as an ambiguous call because of how LÖVR's overloads are declared; giving the wrap, horizontal, and vertical alignment arguments, as the examples do, selects the transform form.
