# Writing plugins

A lunette configuration is a LÖVR project whose `main.luau` composes the shipped desktop and adds or replaces plugins in it. A plugin is a definition: a name, the contracts it requires and provides, and an initializer that runs when the plugin activates. The plugin runtime releases everything an activation acquired when that activation ends.

The code in this guide comes from the configurations under `examples/`: `first-plugin`, `keyboard`, `layout`, `theme`, `ui`, and `desktop`. `make check` typechecks them and runs each in the desktop test harness. [The Lua API](../dev/lua-api.md#plugin-authoring) is the specification this guide follows. [The native API](native-api.md) describes the `lunette` module beneath the plugins.

## A configuration to work in

`lunette --dump-config` writes `main.luau`, `conf.luau`, and a `.luaurc` to `$XDG_CONFIG_HOME/lunette`, or to a directory given after the flag. The `.luaurc` names the installed Lua roots by absolute path, which lets `lunette check` and an editor resolve `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`. A `.luaurc` copied by hand from the source tree names relative paths that do not exist beside the copy. From an uninstalled source tree, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` writes a `.luaurc` that names the tree's roots.

The shipped `main.luau` is one call:

```luau
require('@lunette-desktop').run()
```

`run` takes `settings` and `patches`. [Desktop configuration](desktop-configuration.md) describes the settings. Patches change the desktop's entry list, which `require('@lunette-desktop').entries()` returns. Each entry has an `id`, such as `keyboard`, `laser`, or `desktop/keyboard`. The built-in providers publish services such as panels, pointers, and the keyboard, and the `desktop/` consumers use them. Every entry is a module under `@lunette-plugins`: a provider under its contract's name and a desktop consumer under `@lunette-plugins/desktop/`, so `desktop/keyboard` is `@lunette-plugins/desktop/keyboard`.

Plugin modules live in the configuration directory and are required by relative path, such as `require './hello'`. A relative path resolves against the directory of the requiring file, in a session and in `lunette check` alike. From `myplugin/init.luau`, `require '@self/draw'` names `myplugin/draw.luau`, because `./draw` from an `init.luau` names a sibling of its directory. A relative path cannot leave the configuration directory. [Module roots](../dev/stdlib.md#module-roots) states the rules.

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
}).definition
```

`plugin.consumer` takes `name`, `requires`, `schema`, and `init`; `requires` and `schema` are optional. `requires` lists the capabilities of the contracts the plugin uses, here the frame contract, which delivers LÖVR's update, draw, key, text, and quit callbacks. `context:require` returns the service behind a required contract. `frames:onDraw(context, ...)` registers a draw handler owned by the plugin's context. The draw phases run in the order `input`, `scene`, `pointing`, `overlay`, and `feedback`.

The configuration inserts the plugin as a new entry:

```luau
require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'hello', definition = require './hello' } },
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
}).definition
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
}).definition
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

The configured module has `definition`, built from the defaults, and `define`, which makes another definition with other defaults and an optional `name`. A patch supplies configuration:

```luau
{ insert = { id = 'uptime', definition = require './uptime', config = { prefix = 'running for' } } },
```

Geometric positions, directions, and offsets are native `vector` values made with `vector.pack(x, y, z)`. Vectors are immutable, so `direction = direction:normalize()` keeps the returned value. `Mat4:translate` accepts a vector. Colours, two-dimensional coordinates, lists, and full matrices keep their own representations.

## Hooking a built-in provider

Behaviour inside a provider changes through a hook: an option whose value is a function that receives the hook's arguments followed by `base`, the default implementation. Calling `base` keeps the default, and not calling it replaces it. The built-in hooks are the keyboard's `onKey` and `drawKey`, interaction's `drive` and `constrain`, the laser's `readInput` and `draw`, placement's `panelOptions`, and the UI provider's `draw`. An error a hook raises is reported where the provider was called from.

Only one active plugin can provide a contract. Where several implementations coexist, as with layouts, themes, menu actions, key bindings, rule sources, and surface offers, one provider is a broker and each implementation registers with it. A name registered with a broker has one holder at a time, and registering a taken name raises an error.

## Configuring a built-in plugin

A patch with an entry's `id` changes that entry. `config` merges into the entry's configuration through the definition's schema: declared objects merge field by field, and arrays, maps, unions, and scalar values replace. A definition without a schema has its configuration replaced. `definition` or `factory` replaces what the entry is made from, and `disabled = true` removes the entry. A patch naming an unknown id, or two patches naming one id, raise an error when the configuration loads. An `insert` patch adds an entry at the end, or `before` or `after` a named entry.

`plugin.configure(id, target)` returns a function that makes a configuration patch for one entry, typed with the target's options. `desktop.configure` is the same function. The target is the entry's definition or factory; `configure` reads only its type and never calls a factory. A built-in provider module holds its definition as `definition`. A desktop consumer module is its definition, or for `desktop/theme` and `desktop/arrange` a factory. `desktop/persistence` is `@lunette-plugins/arrangement`, which holds its factory as `factory`.

```luau
local desktop = require '@lunette-desktop'
local laser = require '@lunette-plugins/laser'

desktop.run {
  patches = {
    desktop.configure('laser', laser.definition) { style = { color = { 1, 0.4, 0.2, 0.6 } } },
    desktop.configure('desktop/keyboard', require '@lunette-plugins/desktop/keyboard') {
      placement = { distance = 0.45 },
    },
  },
}
```

The checker rejects a wrong value type in a `configure` patch, such as `placement = { distance = 'far' }`. It does not check a plain patch's `config`, because a patch list mixes entries. A misspelt key is not a Luau type error in either form; runtime validation rejects it with an error naming its path. [Contracts and providers](../dev/stdlib.md#contracts-and-providers) lists each built-in provider's options.

## Themes

`desktop/theme` selects the theme through `lunette/theme`. A configuration names the initial theme and can override fields of it:

```luau
desktop.configure('desktop/theme', require '@lunette-plugins/desktop/theme') {
  preset = 'arcade',
  overrides = {
    colors = { focus = { 1, 0.5, 0.1, 1 } },
    typography = { bodySize = 20 },
  },
},
```

[Runtime themes](desktop-configuration.md#runtime-themes) describes the selector and its menu.

A plugin reads the theme through `@lunette-contracts/theme`. `theme.Theme` is a complete immutable value with `colors`, `typography`, `metrics`, and `radii`. `service:current()` returns `{ revision, theme }`, and `service:onChanged(owner, run)` calls `run` with a new snapshot after each change. `service:font(spec)` returns the font face for a `theme.FontSpec`, or for the current theme's font when `spec` is omitted. The provider caches one face per specification, so a plugin asks again after a theme change instead of keeping a face. `service:select(owner, overrides)` returns a registration whose overrides apply over the base theme; the most recent live registration wins. [Runtime themes](../dev/lua-api.md#runtime-themes) specifies the contract.

The built-in UI, keyboard, panels, and laser read the theme provider, so a custom composition that uses them includes the `theme` entry.

## Adding a theme

The themes that `desktop/theme` offers come from the `lunette/themes` catalog. A plugin adds one by registering a complete theme under a name, and the theme's menu row lasts as long as the registration. `examples/theme/dusk.luau` registers Dusk, the standard Dark theme with a warmer palette:

```luau
local dusk = descriptors.resolve(standard.presets.dark, {
  colors = { background = { 0.10, 0.05, 0.06, 1 }, focus = { 1, 0.60, 0.25, 1 } },
})

catalog:register(context, { name = 'dusk', label = 'Dusk', order = 4, theme = dusk })
```

`descriptors.resolve` fills omitted fields from the theme it starts from, here Dark. `order` places the row among Dark at 1, Light at 2, and Arcade at 3. Registering a name that another live registration holds raises an error.

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
return keyboard.define {
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
}
```

`pointer:vibrate` pulses the controller that pressed the key. `key.source` is the row entry the key was made from and stays the same table across frames. `@lunette-plugins/keyboard/draw` has the default drawing's parts, including `legend` and `faceColor`. `examples/keyboard/rounded.luau` draws rounded faces with the default legends. The built-in key and backing radii already follow the theme, so rounding needs no hook.

The definition replaces the desktop's keyboard by id, and every plugin that requires the keyboard contract then receives it:

```luau
{ id = 'keyboard', definition = require './split' },
```

## Replacing the keyboard

A plugin that provides `lunette/keyboard` at schema 3 can take the keyboard entry's place. `service:new(owner, options)` returns a keyboard, which is a surface with `setVisible`, `pressKey`, `typeText`, `modifiers`, `draw`, and `destroy`, and `service:inspect()` returns its registrations. A replacement sends keys through a virtual focus source and reports visibility changes through `options.onVisibilityChanged`. [Keyboard](../dev/lua-api.md#keyboard) and [Keyboard routing](../dev/input.md#keyboard-routing) specify the rules. `examples/keyboard/tiny.luau` implements the contract with one row of three keys.

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
local optionsSchema = schema.default(descriptor)(descriptor.parse {})

local function grid(panels: { read [number]: layouts.Panel }, given: unknown?): ()
  local options = optionsSchema.parse(given, 'grid')
  -- Poses each panel in a grid cell with panel:setPose.
end

-- In the consumer's init:
service:register(context, { name = 'grid', apply = grid })
```

The layout receives a read-only list of live panels and the options for its name. `desktop/arrange` passes the adopted windows of a tag that were placed without a pose and that the user has not dragged. The layout validates its own options. The registration ends with the plugin, and registering a name twice raises an error.

The configuration inserts the plugin and selects the layout:

```luau
settings = {
  arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
},
patches = {
  { insert = { id = 'grid-layout', definition = require './grid' } },
},
```

`options` is keyed by layout name, so a tag that selects `grid` with `tag:setLayout` receives the same options. `desktop/arrange` arranges again when a layout registers, and logs a warning after the first frame if its chosen layout is not registered.

A layout registered with `continuous = true` is applied every frame. `examples/layout/follow.luau` keeps windows on an arc that turns to follow the head, reusing `@lunette-plugins/layout/arc/geometry`. To replace `arc`, disable the `layout/arc` entry and register another layout under that name.

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
desktop.configure('interaction', require('@lunette-plugins/interaction').definition) { constrain = require './upright' },
```

`drive(pointer, input, surfaces, base)` runs every frame for every pointer, and `base` maps grip to grab, buttons to clicks, and the stick to scrolling or reach. A hook that calls `base` with changed input remaps it. A hook that does not call `base` drives the pointer's `hover`, `setButton`, `beginGrab`, `dragTo`, and `endGrab` itself, and `@lunette-plugins/interaction/picking` has the default picking and scrolling. `focusOnPress = false` stops a click from moving keyboard focus.

The laser's `buttons` option maps controller buttons to pointer buttons, and a list replaces the default:

```luau
desktop.configure('laser', require('@lunette-plugins/laser').definition) {
  buttons = {
    { control = 'trigger', button = 'left' },
    { control = 'a', button = 'right' },
  },
},
```

A plugin that moves surfaces for a pointer, as a replacement interaction would, announces each drop through `lunette/drops`. The desktop remembers a dropped window's place and saves the arrangement only on those drops.

## Menu actions and key bindings

Session controls are menu actions, because every session workflow is reachable with VR controllers. A plugin registers an action with `lunette/menu`, and the wrist menu draws it. `examples/desktop/hide-windows.luau` registers Hide windows, which hides every window and updates the action's `selected` state. `examples/desktop/save-menu.luau` registers Save arrangement and Restore arrangement. [Bindings, menu actions, and layouts](../dev/lua-api.md#bindings-menu-actions-and-layouts) specifies the broker.

`panel:setHidden(context, { hidden = true })` hides a panel while the plugin holds the returned effect. A hidden panel is not drawn or pointed at and keeps its place. When several plugins hide or show one panel, the most recent override still held decides.

A key binding is an optional chord registered with `lunette/bindings`, for input beyond the session controls. The bindings provider sees each key press before `desktop/input` delivers it to a window, so a bound key never reaches a window. The modifiers are `control`, `alt`, `logo`, and `shift`, and a chord matches only with exactly those held. Binding a chord that is already bound raises an error. The binding ends with the plugin.

## Decorations

`desktop/decorations` gives native panels the shared UI titlebar, which carries the title, a close button, and the monitor controls, and moves its panel when dragged. Its `style` is the `decorations` setting:

```luau
settings = {
  decorations = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
},
```

Other decorations are a plugin that does what `lua/lunette-plugins/desktop/decorations/init.luau` does. It creates a titlebar for each panel in `panels:all()` with `ui:newTitlebar(owner, name, target, options, visible?)` and destroys it from `panels:onRemoved`. Disabling `desktop/decorations` and inserting such a plugin replaces it. [Joined frame attachments](../dev/lua-api.md#joined-frame-attachments) specifies how a titlebar joins its target's outline.

## Tags and workspaces

A tag is a named group of panels. Adoption puts every window in `main` unless a rule names other tags, and `desktop/arrange` arranges each tag. A plugin that needs a tag holds it, which creates it if no plugin has, so start order does not matter:

```luau
local web = tagService:hold(context, { name = 'web' })
```

The tag lasts while any plugin holds it. A plugin moves a window that another plugin put in a tag by excluding it there and adding it elsewhere, and the window returns when the plugin deactivates:

```luau
main:exclude(context, { panel = panel })
web:add(context, panel)
```

`tags:onChanged(context, { run = function(change) end })` reports tags created and destroyed and changes to their selection, layout, and members; `change.kind` names the change and `change.tag` the tag. `web:setLayout(context, { layout = 'grid' })` makes `desktop/arrange` use that layout for the tag.

`desktop/workspaces` shows one workspace's windows at a time. The `workspaces` setting lists the workspaces, and with more than one the consumer registers a menu action for each. [Workspaces](desktop-configuration.md#workspaces) describes the setting. A workspace consumer of another kind listens to `onChanged` and hides panels with `setHidden` in the same way.

## Rules

`desktop/rules` takes the rule list. A rule matches window fields such as `appId` or `title`, or `where`, a predicate over the whole window, and its properties say where the window goes and how big it is. `examples/desktop/main.luau` sizes picture-in-picture windows by title:

```luau
settings = {
  rules = {
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

`errors:recent()` returns the retained reports, so a presenter that starts late can show them, and `errors:clear(context)` dismisses them for every presenter.

## Saving the arrangement

The desktop saves window positions when a window is dropped and at quit. A window is identified across sessions by its application id. `desktop/persistence` takes the file name, through the `persistence` setting:

```luau
settings = {
  persistence = { file = 'example.state' },
},
```

It also provides `lunette/arrangement`, whose `save` and `restore` methods `examples/desktop/save-menu.luau` calls. A file that cannot be read, or that a newer version wrote, is not overwritten; [Default configuration](../dev/stdlib.md#default-configuration) states the rules.

## Frame rates and sharpness

`desktop/pacing` lowers the frame rate of a hidden panel's window unless its content type is exempt, and `desktop/scale` raises an output's scale in steps as the head approaches its nearest panel. The `pacing` and `scale` providers hold the tuning:

```luau
desktop.configure('pacing', require('@lunette-plugins/pacing').definition) { tuning = { background = 5, exemptTypes = { photo = true } } },
desktop.configure('scale', require('@lunette-plugins/scale').definition) { tuning = { reference = 0.8 } },
```

A replacement rule is a plugin that provides `lunette/pacing` or `lunette/scale` in the provider's entry. A different policy, such as pacing by gaze, is a consumer in place of `desktop/pacing`. Disabling `desktop/pacing` or `desktop/scale` leaves every client at its own rate or scale. [Frame pacing and output scale](../dev/lua-api.md#frame-pacing-and-output-scale) states the rules.

## Checking a configuration

`lunette check` typechecks every `.luau` file in the configuration directory, and every module they require, in strict mode against the runtime's definitions. Naming files or directories, as in `lunette check main.luau`, checks those instead. The checker reports type errors, accidental globals, locals used before their declaration, and capabilities with no service type. It does not run descriptors or initializers. Invalid settings and patches raise an error when the configuration loads, an invalid entry configuration stops startup before any plugin activates, and an initializer error fails only that plugin's activation.
