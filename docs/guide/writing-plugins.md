# Writing plugins

A lunette configuration is a LÖVR project whose `main.lua` composes the shipped desktop and adds or replaces plugins in it. A plugin is a definition: a name, the contracts it requires and provides, and an initializer that runs when the plugin loads. Everything a plugin creates while it loads is undone when it unloads.

The code in this guide is in four example configurations, `examples/first-plugin`, `examples/keyboard`, `examples/layout`, and `examples/desktop`. `make check` typechecks all four and runs them in the desktop test harness, so the code here is code that works. [The Lua API](../dev/lua-api.md#plugin-authoring) is the specification this guide follows.

## A configuration to work in

`lunette --dump-config` writes `main.lua` and `conf.lua` to `$XDG_CONFIG_HOME/lunette`, or to a directory given after the flag, together with a `.luaurc` that names the Lua roots by absolute path. The `.luaurc` is what lets `lunette check` and an editor resolve `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`. A configuration copied by hand from the source tree carries a `.luaurc` whose relative paths point nowhere. From a source tree that is not installed, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` writes one that names the tree's roots.

The shipped `main.lua` is one call:

```lua
require('@lunette-desktop').run()
```

`run` takes `patches`, which change the desktop's list of plugins. `require('@lunette-desktop').entries()` answers that list; each entry has an `id`, such as `keyboard`, `laser`, or `desktop/keyboard`. The built-in plugins provide services, such as panels, pointers, and the keyboard, and the `desktop/` entries use them: `desktop/render` draws the panels, `desktop/decorations` gives them title bars, `desktop/pointing` points the lasers, and so on.

Plugin modules go in the configuration directory and are required with a relative path such as `require './hello'`. A relative path starts from the directory that holds the requiring module, in a session and in `lunette check` alike, so a plugin split across `myplugin/init.lua` and `myplugin/draw.lua` requires its part as `require '@self/draw'`: an `init.lua` is the module its directory names, so `./draw` from it would be a sibling of the directory. A relative path cannot climb out of the configuration directory.

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

`desktop.configure` makes a configuration patch for each shipped entry that takes options, typed with that entry's options, so the checker reads them:

```lua
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    desktop.configure.laser { style = { color = { 1, 0.4, 0.2, 0.6 } } },
    desktop.configure['desktop/keyboard'] { hand = 'right', placement = { distance = 0.45 } },
  },
}
```

`desktop.configure['desktop/keyboard'] { hand = 'rigth' }` is a type error, where `{ id = 'desktop/keyboard', config = { hand = 'rigth' } }` passes `lunette check`: a patch list mixes entries, so a plain patch's `config` has no type of its own. An id with a slash is indexed as a string. A misspelt key is not a type error in Luau either way; each entry validates its options when it loads and raises an error naming the option. Each built-in provider's options are listed in [the standard library](../dev/stdlib.md#contracts-and-providers) and, for the keyboard, in [Keyboard](../dev/lua-api.md#keyboard).

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

`context:acquire` checks that the owner is a live plugin and registers the release with the owner, so a keyboard ends with the plugin that asked for it. Each owner draws and offers its own keyboards, so a provider keeps no list of them. A surface callback that answers a ray hit, `raycast`, is annotated `(number?, number?, number?)` when it is written as a method or a local function. Luau gives a function with no expected type the return type of its first `return`, so an unannotated `raycast` that misses with `return nil, nil, nil` before it returns the hit is rejected at the hit. A `raycast` written inside a table that is annotated as the surface type takes its type from the contract and needs no annotation.

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
    panel:setPose(lovr.math.newMat4():translate(x, y, options.center[3]))
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

The layout receives the live panels in the order the caller gives them and the caller's options. It decides nothing about which panels it gets: `desktop/arrange` passes the adopted windows of the workspace tag that were placed without a pose, less any the user has since dragged. `plugin.options` checks the options against the defaults, so a misspelt option raises an error naming it. The registration is owned by the plugin's context, so it ends when the plugin unloads, and a second registration of the same name raises.

Two patches add the grid and choose it:

```lua
{ insert = { id = 'grid-layout', definition = require './grid' } },
desktop.configure['desktop/arrange'] { layout = 'grid', options = { grid = { columns = 3 } } },
```

`options` gives each layout its options by name, and `desktop/arrange` passes a layout its own whichever tag uses it, so a tag that chooses `grid` with `tag:setLayout` is laid out in three columns too. An inserted entry is enabled after the shipped ones, so the grid registers after `desktop/arrange` has started, and `desktop/arrange` arranges again when it does. If no layout of the chosen name has registered by the first frame, `desktop/arrange` logs a warning naming it.

A layout registered with `continuous = true` is applied on every frame as well. `examples/layout/follow.lua` is one: it keeps the windows on an arc around the head and swings the arc round once the head has turned far enough away from it. It reuses the arc layout's geometry, `@lunette-plugins/layout/arc/geometry`, which spaces panels by their widths so that wide ones do not overlap. `examples/layout/main.lua` inserts both layouts and chooses the grid; `layout = 'follow'` chooses the other.

To replace the built-in arc rather than add beside it, disable the `layout/arc` entry and register another layout as `arc`. A layout is never overridden in place.

## Changing how pointers behave

The interaction provider turns each frame of a laser's input into hovering, clicking, scrolling, and carrying. It has two hooks. `constrain(surface, pose, base)` answers where a carried surface goes for where the hand would put it, so a rule about how panels move is one function. `examples/desktop/upright.lua` keeps carried panels level:

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
desktop.configure.interaction { constrain = require './upright' },
```

`drive(pointer, input, surfaces, base)` runs for every frame of every pointer, and `base` is the default mapping: grip to grab, buttons to click, the stick to scroll or push. A hook that calls `base` with changed input remaps it, and one that does not call `base` drives the pointer's primitives, `hover`, `setButton`, `beginGrab`, `dragTo`, and `endGrab`, itself. `@lunette-plugins/interaction/picking` has the default's picking and scrolling for such a hook. `focusOnPress = false` stops a click from giving the keyboard to what it clicks.

Which controller button presses which pointer button is the laser's `buttons` option, a list that replaces the default:

```lua
desktop.configure.laser {
  buttons = {
    { control = 'trigger', button = 'left' },
    { control = 'a', button = 'right' },
  },
},
```

A plugin that moves surfaces for a pointer, as a replacement interaction would, announces each drop through `lunette/drops`. The desktop remembers a dropped window's place, saves the arrangement, and keeps a dropped window out of the automatic arrangement only because it hears those drops.

## Key bindings

A key binding is a chord registered with `lunette/bindings`. The bindings provider takes every key press before `desktop/input` sends keys to a window, so a bound key never reaches one, and while the bindings provider is out, keys still reach windows. `examples/desktop/hide-windows.lua` binds control, alt, and H to hide every window and show them again:

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

The reload key is the `desktop/bindings` entry's binding, so it moves with a patch:

```lua
desktop.configure['desktop/bindings'] { reload = { key = 'f5', modifiers = { 'control' } } },
```

## Decorations

Panels draw no frame of their own. The `desktop/decorations` entry draws a border round each panel and a title bar above it, and grabbing the bar moves the panel. Its `style` is configuration, as in `examples/desktop/main.lua`:

```lua
desktop.configure['desktop/decorations'] { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
```

Decorations of another kind are a plugin that does what `lua/lunette-desktop/decorations.lua` does: it hears panels arrive and leave through `panels:onAdded` and `panels:onRemoved`, draws in the frame's `scene` phase, and offers its bars with `surfaces:offer`. A bar is a surface whose `setPose` moves its panel, and it carries the panel's `kind` and `source`, so dropping it counts as dropping the panel. Disabling `desktop/decorations` and inserting such a plugin replaces it.

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

The shipped `desktop/workspaces` consumer shows one workspace's windows at a time and hides the rest. It is not in the default desktop; `examples/desktop/main.lua` inserts it with two workspaces on control, alt, and a number:

```lua
{
  insert = {
    id = 'desktop/workspaces',
    definition = require '@lunette-desktop/workspaces',
    config = {
      workspaces = { { name = 'main', key = '1' }, { name = 'side', key = '2' } },
      modifiers = { 'control', 'alt' },
    },
  },
},
```

A window that opens goes to the workspace in view. A workspace consumer of another kind, such as one switched by a gesture, listens to `onChanged` and hides panels with `setHidden` the same way.

## Rules

`desktop/rules` takes the rule list. A rule matches named fields of a window, such as `appId` or `title`, or `where`, a function of the whole window, and its properties say where the window goes and how big it is. `examples/desktop/main.lua` sizes picture-in-picture windows by their title:

```lua
desktop.configure['desktop/rules'] {
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

A rule's `hidden = true` places a window hidden, `adopt = false` leaves it out of the desktop altogether, and `tags` names the tags it joins. A property the desktop does not know reaches the panel only through a placement of your own: `placement.define { panelOptions = function(properties, window, base) ... end }` receives the resolved properties and the default mapping, as [Rules and placement](../dev/lua-api.md#rules-and-placement) shows. A plugin that resolves properties from somewhere else, such as a file, registers a source with `rules:addSource`, at a precedence named relative to `require('@lunette-contracts/vocabulary').PRECEDENCE`; a source above `PRECEDENCE.persisted` overrides the saved arrangement.

## Presenting errors

Errors reach plugins through the `lunette/errors` stream, which has already dropped repeats. The shipped `desktop/errors` draws the latest one over the scene; its position, size, and colour are its configuration. Any plugin can present them as well. `examples/desktop/notify-errors.lua` sends each as a desktop notification:

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

`errors:recent()` answers the reports kept so far, so a presenter that starts late can show what it missed, and `errors:clear(context)` dismisses them for every presenter. Disabling `desktop/errors` leaves your presenter the only one.

## Saving the arrangement

The desktop saves where the windows are whenever one is dropped, and at quit. `desktop/persistence` takes the file it saves to, the format it writes, and `keyFor`, which says what identifies a window across sessions, by default its application id:

```lua
desktop.configure['desktop/persistence'] { file = 'example.state' },
```

It also provides `lunette/arrangement`, so a key can save or put the windows back. `examples/desktop/save-key.lua` binds control, alt, and S to save and control, alt, and R to restore:

```lua
keys:register(context, {
  chord = { key = 's', modifiers = { 'control', 'alt' } },
  run = function(_press: bindings.Press)
    local written, message = saved:save()
    local log = lovr.log
    if not written and log then
      log('the arrangement was not saved: ' .. tostring(message), 'warn', 'save-key')
    end
  end,
})
```

A format of your own is a `{ read, render }` pair; [Default configuration](../dev/stdlib.md#default-configuration) states what `read` answers so that a file written by a newer version is left alone rather than overwritten.

## Checking a configuration

`lunette check` typechecks every `.lua` and `.luau` file in the configuration directory a session would load, and every module they require, in strict mode, against the runtime's definitions. Naming files or directories, as in `lunette check main.lua`, checks those instead. The checker reports type errors, an accidental global, a local used before it is declared, and a capability with an unknown service type. It checks the options of a `desktop.configure` patch but not a plain patch's `config`, and it does not run the plugins: an option error, a malformed row, or an error raised in `init` appears when the session loads the plugin, in the log and in the error panel, naming the plugin.
