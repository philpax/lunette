# The Lua API

## Two roots

```lua
local lunette = require '@lunette'        -- native mechanism.
local plugin = require '@lunette-plugin'  -- the plugin facade, written in Lua.
```

`lunette` exposes native mechanism: windows, monitors, sinks, seats, outputs, processes, layer claims, clipboard bridging, capture, events, and the plugin runtime. Policy is Lua. The plugin facade, the neutral contracts, the built-in plugins, and the shipped desktop live under `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`. The Lua roots use only public APIs and contracts, and `lunette` remains usable without any of them.

[Module roots](build-and-development.md#module-roots) lists the aliases and their runtime resolution, and [the standard library's module roots](stdlib.md#module-roots) states how a relative require resolves. The static checker runs separately from the session; starting lunette does not run it.

## The config

`~/.config/lunette/main.luau` is a LÖVR project. It defines the LÖVR callbacks and requires lunette's libraries like any other module. No loop runs on the user's behalf unless this file defines it.

When the file does not exist, lunette runs `$SYSCONFDIR/xdg/lunette/main.luau` directly, so an unedited configuration never goes stale. `lunette --dump-config` writes a copy to edit. The shipped configuration runs the `@lunette-desktop` composition. A configuration that uses `lunette` alone, or only some providers, is supported.

## Plugin authoring

[Writing plugins](../guide/writing-plugins.md) is the guide; this section and the ones after it are the specification it follows.

A contract module defines a service type, declares the contract with `plugin.capability`, and exports the capability:

```lua
local capability = plugin.capability<<Service>> { name = 'example/service', schema = 1 }
```

The name is authority-qualified and the schema is a positive integer. Explicit type instantiation fixes the service type. The capability is frozen and binds one native contract token when it is created. A Lua state cannot declare the same name and schema twice in one epoch. `lunette check` reports any call that produces a capability with an unknown service type, which is what omitting `<<Service>>` produces.

A definition is a table of named fields:

```lua
return plugin.define {
  name = 'my-layout',
  requires = { tags = tags.capability },
  provides = { layout = myLayout.capability },
  init = function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    local service: tags.Service = context:require(tags.capability)
    publish:provide(myLayout.capability, create(context, service))
  end,
}
```

`name` labels the definition in logs, reports, and diagnostics and need not be unique. `requires` and `provides` map field names to capabilities and default to empty. `init` receives a `Context`, the configuration, and a `Publisher`, and returns nothing. The facade rejects an unknown field or a value of the wrong type in a definition or capability spec, and the error names the problem and the call.

`Context:require(capability)` returns the required service, typed by the capability. `Publisher:provide(capability, value)` stages a provision of the matching type and is valid only while the initializer runs. The native runtime publishes the staged values as one provider generation after the initializer returns successfully. A failed or cancelled initializer publishes nothing and its effects are rolled back. The runtime matches contracts by exact name and schema; a consumer whose requirement has no provider of that schema does not activate. It rejects undeclared access, undeclared, duplicate, or nil provisions, and calls to an expired publisher. It does not check service shapes or configuration values against Luau types. Plugin callbacks are synchronous.

### Context operations

- `Context:effect(acquire)` runs `acquire`, which returns an inverse, and registers that inverse with the activation. If the activation is cancelled during acquisition, the inverse runs at once and the call raises. Disposing an effect whose activation has ended does nothing.
- `Context:on { event = subscribe, run = handler }` makes a subscription an effect. `event` is any function of the `lunette.on*` shape, which takes a handler and returns a cancel function. The handler is not called after the activation ends.
- `Context:child(definition, config)` installs and enables a child instance owned by the activation, which is retired when the activation ends.
- `Context:active()` reports whether the activation may still acquire resources.
- `Context:checkOwner(owner)` raises unless `owner` is a live context bound to this provider's current generation. `Context:owns(owner)` answers the same question as a boolean.
- `Context:acquire(owner, acquire)` checks the owner and registers the effect on the owner's activation, which is the shape of an owner-scoped provider method. `Context:acquireDeferred` does the same without draining queued lifecycle work before it returns.
- `Context:resource(owner, acquire)` takes an acquisition that returns a value and its inverse, and returns the value and the effect after registration succeeds. An acquisition that raises before returning releases its own partial resources.

Only contexts the facade created are accepted as owners. `plugin.ownerLabel(owner)` returns an owner's definition name for diagnostics, or `unregistered owner`; it grants nothing.

### Services

A consumer receives each provision through a frozen view shared by every consumer of that provider generation. Reading, iterating, or calling through the view raises an error naming the contract once the provider has begun unloading, including through a reference kept past the consumer's own activation. Assigning a field always raises. A method receives the view as `self`, so a provider keeps mutable state in its own locals. The view checks a method when it is read, so a function read while the provider was live stays callable, and objects a method returned carry their own `dead` state. `pairs` and `#` see an empty table; generalized iteration and field reads see the service.

### Confinement

A plugin changes state outside itself only through its context. Every resource, subscription, and child an initializer creates goes through `effect`, `on`, `child`, or an owner-scoped provider method, so unloading the instance reverts it. A direct `lunette.onWindowOpened` call is untracked: it survives instance reload and is duplicated by the next activation.

Effects are flat. An effect created during another effect's acquisition registers first, as a sibling, and inverses run in reverse registration order, so the outer inverse runs before the inner one. An outer inverse that must release the inner resource first disposes it itself.

An owner-scoped provider method registers its resource on the caller's owner. A provider that needs one of its own services for that work calls the service with its own context as owner, inside the effect it registers for the caller. Forwarding the caller's owner would require the caller to depend on the provider's dependencies.

Two active instances cannot provide the same contract and schema. Several implementations of one contract compose through a broker, as section 6.2 of the Cordis paper describes: one plugin provides the contract and implementations register with it through an owner-scoped method. Layouts, themes, menu actions, bindings, rule sources, and surface offers are brokers.

### Instances

`Runtime:use(definition, config)` installs an instance. An instance has `enable`, `disable`, `dispose`, `reload(config)`, and `requestReload(config)`; runtime shutdown disposes every instance. A request takes effect immediately and raises at the call when the graph rejects it, such as an enable of a retired instance or of one whose provided contract another enabled instance reserves. `requestReload` accepts the replacement without draining; `Runtime:drain()` applies it. An initializer or inverse that fails during a drain is reported through [the error path](#errors) rather than raised from the request.

`instance:state()` is one of `inactive`, `loading`, `active`, `unloading`, `failed`, `quarantined`, and `removed`. `instance:diagnostic()` describes why it last failed or is not loading. `instance:id()` is an exact decimal string. [Architecture](architecture.md#plugin-runtime) states the reservation, retry, and quarantine rules.

Contract tokens belong to one Lua state's epoch. Source reload retires the epoch, so a new configuration may declare the same names and schemas again, and a capability from the retired epoch is rejected. Instance reload replaces one activation within its runtime and epoch. The native plugin handles in `lua/lunette/init.luau` are nominal types, so a table does not satisfy a parameter that takes a token, definition, runtime, instance, context, or effect.

### Runtime inspection

`Runtime:owns(instance)` and `Runtime:ownerId(owner)` identify instances and owning contexts. `Runtime:snapshot()` returns a detached, read-only snapshot of instances, bindings, and effects without running callbacks or draining work. Identities in it are exact decimal strings. [Session composition and inspection](stdlib.md#session-composition-and-inspection) states how the desktop uses it and what broker inspection adds.

### Provider modules

Every built-in provider module has one shape:

```lua
local laser = require '@lunette-plugins/laser'
laser.definition                                             -- the default definition
laser.define { name = 'long-laser', style = { length = 3 } } -- a definition with other defaults
laser.build(context, { style = { length = 3 } })             -- the service, unpublished
laser.requires                                               -- what build reads from the context
```

A provider's options are its configuration. `runtime:use`, a composition patch's `config`, `define`, and `build` all take the provider's `Config`, and a descriptor supplies defaults and validates it. Declared objects merge recursively; arrays, maps, unions, and atomic values replace, so an empty map clears a map. `define` takes options and an optional `name` and returns a definition with those settings as its base. Each activation resolves its configuration afresh. A module exports `Config`, the table a caller writes, and `Settings`, the resolved value its builder receives.

`build(context, config)` makes the service without publishing it, so a plugin can wrap it and publish the wrapper under the same contract. The wrapping plugin declares `laser.requires` among its requirements, and effects `build` registers belong to the wrapping activation:

```lua
plugin.define {
  name = 'counting-laser',
  requires = laser.requires,
  provides = { laser = laserContract.capability },
  init = function(context, config, publish)
    local inner = laser.build(context, config)
    publish:provide(laserContract.capability, setmetatable({
      attach = function(_self, owner, options)
        attached += 1
        return inner:attach(owner, options)
      end,
    }, { __index = inner }))
  end,
}
```

A wrapper changes only what reaches the service from outside, because a built-in calls its own methods through closures. Variation inside a provider is a hook: an option whose value is a function that receives its arguments followed by the default implementation, `hook(args..., base)`, and calls `base` to keep the default. A hook runs on the stack of whatever reached the provider, so its errors are reported there. The built-in hooks are the keyboard's `onKey` and `drawKey` ([Keyboard](#keyboard)), interaction's `drive` and `constrain` ([Pointers and interaction](#pointers-and-interaction)), the laser's `readInput` and `draw` ([Lasers](#lasers)), placement's `panelOptions` ([Rules and placement](#rules-and-placement)), and the UI provider's `draw` ([UI panels](#ui-panels)).

`plugin.provider<<Config, Settings, Service>> { name, capability, requires, schema, build }` makes such a module. `plugin.consumer<<Config, Settings>> { name, requires, schema, init }` makes a configured consumer with `definition`, `define`, and `requires`; its `init` receives the resolved settings and reads services with `context:require`. `Config` is `schema.Input<typeof(descriptor)>` and `Settings` is `schema.Output<typeof(descriptor)>`. A spec without `schema` takes no options. The descriptor validates defaults at construction, bound settings at `define`, options at `build`, and configuration at activation. A configured definition carries its `schema` metadata and a `resolve` function for preflight. [Configuration schemas](../guide/configuration-schema.md) states the descriptor constructors and errors.

`plugin.rejectUnknownFields(prefix, value, allowed, fields, level)` raises `<prefix>: unknown field <key>; the fields are <fields>` for a key outside `allowed`, and the built-in providers check their method arguments with it. `plugin.checkVector(name, option, value)` checks a native `vector` and rejects a non-finite component. Three-dimensional positions, directions, and offsets are native vectors in configuration and settings; colours, two-dimensional coordinates, and pose matrices keep their own representations.

### Composition

A composition is a list of entries, `{ id, definition, config }` or `{ id, factory, config }`. A factory makes the definition once per start, so the definition can keep state across its own provider outages. `plugin.compose(entries, patches)` returns the entries with the patches applied, validated, and frozen, and defines and enables nothing. `lua/lunette-plugin/compose.luau` is the source of truth for the rules below.

```lua
plugin.compose(entries, {
  { id = 'keyboard', disabled = true },
  { id = 'laser', definition = myLaser },
  { id = 'interaction', config = { tuning = { reach = 4 } } },
  { insert = { id = 'my-hud', definition = hud, config = {} }, before = 'desktop/adoption' },
})
```

`disabled = true` removes the entry. `definition` or `factory` replaces what the entry is made from and keeps its configuration. `config` merges over the entry's configuration by the definition's descriptor, reading a factory's descriptor by calling it; a definition without a descriptor takes the patch's configuration in place of the entry's. `insert` adds an entry at the end or `before` or `after` another, and carries no other field. Each id names one entry and one keyed patch. `compose` raises, naming the id, for an unknown id, a duplicate, an unknown field, a patch that both disables and changes an entry, one that gives both a definition and a factory, and one that changes nothing.

`plugin.configure(id, definitionOrFactory)` returns a function that makes the patch `{ id = id, config = config }` with `config` typed by the definition's `Config`, as in `plugin.configure('laser', laser.definition) { style = { length = 3 } }`. It never calls a factory. A plain patch's `config` is untyped. `desktop.configure` is the same function.

`@lunette-plugin/management.start(entries, { protected })` starts a composition. It preflights every configuration through its definition's `resolve` before creating the runtime, so a configuration error aborts startup before any entry activates. Initializer failures stay local to their instances. The entry id `composition` is reserved for the composition service. [Session composition and inspection](stdlib.md#session-composition-and-inspection) describes entry management and recovery.

## Contracts

Each contract module under `lua/lunette-contracts/` is the source of truth for its types and signatures. Every registration that takes an owner returns an effect and ends when the effect is disposed or the owner unloads. A listener or callback a provider invokes for another plugin runs under its own protected call, and its error is reported through `lunette.reportError` without stopping the others. A call with a field the contract does not name raises at the call.

### Frame and surfaces

LÖVR's frame and input callbacks reach plugins through `lunette/frame` at schema 2, and the surfaces a pointer can pick are listed by `lunette/surfaces`. The built-in `@lunette-plugins/frame` and `@lunette-plugins/surfaces` providers implement them.

```lua
frame:onBatch(owner, { run = function(batch) end })
frame:onUpdate(owner, { phase = 'scene', order = 0, run = function(dt) end })
frame:onDraw(owner, { phase = 'overlay', run = function(pass) end })
frame:onKey(owner, { phase = 'binding', run = function(event) return event.key == 'f5' end })
frame:onText(owner, { phase = 'delivery', run = function(event) end })
frame:onQuit(owner, { run = function() end })
surfaces:offer(owner, { name = 'my-hud', list = function() return { hud } end })
surfaces:all()
```

Update handlers run in the phases `input`, `scene`, `pointing`, and `overlay`, and draw handlers in those and then `feedback`; `@lunette-contracts/frame` exports them as `UPDATE_PHASES` and `DRAW_PHASES`. `input` reads devices before the scene moves. `scene` updates and draws panels. `pointing` picks against this frame's surface poses. `overlay` draws UI over the scene. `feedback` draws pointer beams and landing indicators after everything else, which is where `desktop/pointing` draws. The phase is required. Within a phase, handlers run by ascending `order`, default 0, then in registration order.

Key and text handlers run `binding` before `delivery`, the default being `binding`, then by order and registration. A handler that returns `true` consumes the event. A key event carries `batch`, `key`, `scancode`, `isRepeat`, and `modifiers`, the physical modifier snapshot or nil. A text event carries `batch`, `text`, and `code`. Quit handlers run in registration order and cannot veto the quit.

An input batch groups the key and text callbacks between two updates. Each update opens a batch before update handlers run, and a key or text callback opens one when none is open. `onBatch` observers receive a frozen `{ id, textBlocked }` before update and key handlers, and immediately on registration when a batch is open. A binding-phase key handler that consumes a key, or a delivery consumer that calls `frame:blockText(id)`, blocks the rest of the batch's text and notifies observers with a new record. `blockText` returns false for an id that is not current. [Input](input.md#physical-input-batches) states how physical sources use this.

Every handler and every offer's `list` runs under its own protected call, reported under the LÖVR callback's name or `surfaces: <name>`. A raising key or text handler consumes nothing, and an offer that raises or returns something other than a table contributes no surfaces. An offer name is unique among live offers. `frame:inspect()` returns handler registration metadata without running a handler.

`frame.install { start, stop }` binds the LÖVR callbacks. It assigns `lovr.load`, which calls `start`, and `lovr.update`, `lovr.draw`, `lovr.keypressed`, `lovr.textinput`, and `lovr.quit`, which reach whichever frame activation is loaded and do nothing while none is. `lovr.quit` runs the quit handlers, then `stop` under a protected call, and returns `false`. One frame activation receives the callbacks at a time. A configuration calls `install` once and creates its runtime in `start`, which is what `@lunette-desktop`'s `run` does.

### Joined frame attachments

A surface may implement the optional `attachFrame(owner, style)` from `@lunette-contracts/vocabulary`, which returns a `FrameAttachment` with `update(style)`, `isJoined()`, and `dispose()`. A `FrameStyle` carries `headerHeight`, `headerRadius`, `borderThickness`, `borderDepth`, and `borderColor`: a positive height, finite nonnegative metre values, and four RGBA components from 0 to 1. Built-in panels and UI panels implement it. The relationship passes resolved header style to the target; it does not provide general transforms or layout.

Attach and update validate and freeze the whole style before changing anything. A target permits one live attachment, and a second raises. Disposal is idempotent, and updating a disposed attachment or one whose target is dead raises. The target computes `isJoined()` each time: a panel joins while it is live, visible, flat, and drawn in the scene rather than on a granted layer, and a UI panel while it is live and visible. An ineligible attachment stays dormant and can join again later.

A joined target draws one outline in the header's border style around the body and header together, even when panel `chrome` is false. Header bottom and body top corners are square and meet with no margin. The target draws the body and the outline; the titlebar draws its header face, text, and actions. [Joined flat frames](rendering.md#joined-flat-frames) defines the geometry.

The shared titlebar acquires one attachment from a supporting target and updates it when the resolved style changes. Hiding the heading, destroying the titlebar, or the owner unloading disposes it. The UI provider synchronizes retained titlebars in one scene update at order 1000, after source and decoration updates and before picking and drawing.

### Keyboard

`lunette/keyboard` at schema 3 makes on-screen keyboards. `keyboard:new(owner, options)` returns a keyboard that the owner places, offers, and draws, ending when the owner unloads or `destroy` is called. A keyboard is a surface with `pose`, `width`, `height`, `visible`, `setPose`, `setSize`, `setVisible`, `pressKey(code)`, `typeText(text)`, `modifiers()`, `draw(pass)`, and `destroy()`. `keyboard:inspect()` returns registration metadata.

`Options` are `rows`, `layers`, and `style`, which override the provider's for that keyboard, plus `pose` and `onVisibilityChanged`. The callback belongs to the owner and receives `{ visible, reason }`, where the reason is `show`, `hide`, `user-hide` (the hide action), or `destroy`. State changes before the callback runs, and an unchanged visibility reports nothing.

Each keyboard delivers through a virtual `lunette/focus` source to the current route. `pressKey` and `typeText` return true only when the input was consumed. A non-modifier key clears latched modifiers; hiding, destruction, and every route change clear latches and locks. Legends and local translation read the source's keymap seat, as [Input](input.md#virtual-activations-and-committed-text) describes. There is no dead-key, compose, or IME support.

Rows are data in the contract. A row is a list of keys laid out left to right. A key has `code`, an evdev code; `action`; `label`, replacing the keymap's legend; `width` and `height` in key units, default 1; and `x`, empty room before the key, default 0. A key with neither code nor action is a spacer. A row advances the next one by its shortest key's height, and an empty row by one unit. An action is `{ kind = 'hide' }`, `{ kind = 'layer', layer }`, `{ kind = 'text', text }`, `{ kind = 'chord', code, modifiers }`, or `{ kind = 'custom', name }`, which does nothing unless a hook handles it.

```lua
local keyboard = require '@lunette-plugins/keyboard'
local codes = require('@lunette-contracts/keys').CODES

local numpad: { keyboard.KeyRow } = {
  { { code = codes.digit7 }, { code = codes.digit8 }, { code = codes.digit9 }, { code = codes.minus } },
  { { code = codes.digit4 }, { code = codes.digit5 }, { code = codes.digit6 }, { action = { kind = 'text', text = '+' }, height = 2 } },
  { { code = codes.digit1 }, { code = codes.digit2 }, { code = codes.digit3 }, { width = 1 } },
  { { action = { kind = 'layer', layer = 'base' }, label = 'abc', width = 4 } },
}
```

The built-in provider's options are `rows`, the base layer, defaulting to `@lunette-plugins/keyboard/rows`; `layers`, further named layers; `style`; `modifierKeys`, mapping codes to latched modifiers, defaulting to `MODIFIER_KEYS` in `@lunette-contracts/keys`; `locks`, defaulting to `lunette.lockingModifierNames()`; and the hooks `onKey` and `drawKey`. A keyboard is as large as its largest layer. The descriptor and `@lunette-plugins/keyboard/validation` reject, by option path, a key with both a code and an action, a layer action naming no layer, and an unknown modifier name.

Keyboard style resolves from the global theme, then the provider's `style`, then `Options.style`. Omitted fields inherit and explicit zeros remain. A theme change refreshes each keyboard before its next input or draw, and a change of font or geometry cancels its pointer captures. Key legends do not write depth. Each key hook and the whole draw restore pass state and transforms, including on error.

`onKey(board, key, pointer, base)` runs for every key a pointer presses, and `base` sends the code or performs the action. `drawKey(pass, key, state, base)` runs for each key after the plate, and `base` draws the face and then the legend. `state` has `keyboard`, `pose`, `style`, `held`, and `hovered`. The board a hook receives adds `layer`, `setLayer(name)`, and `keys()` to the contract's keyboard. A laid-out key's `source` is the row entry it came from. `@lunette-plugins/keyboard/draw` exports `face`, `legend`, and `faceColor`, and `@lunette-plugins/keyboard/layout` holds the pure layout functions `keysOf`, `extentOf`, `keyAt`, and `legendFor`.

```lua
return keyboard.define {
  name = 'clicky-keyboard',
  layers = { numpad = numpad },
  onKey = function(board, key, pointer, base)
    pointer:vibrate { strength = 0.2, duration = 0.01 }
    base(board, key, pointer)
  end,
}
```

### Keyboard display

`lunette/keyboard-display` at schema 1 owns the visibility of the one session keyboard. `desktop/keyboard` provides it, requiring keyboard, focus, frame, surfaces, and UI, and is configured by `settings.keyboardDisplay.placement` with `distance`, `drop`, and `tilt`. The service has `show()`, `hide()`, `toggle()`, `isVisible()`, and `onChanged(owner, { run })`, whose change records carry `visible` and a reason of `show`, `hide`, `user-hide`, or `destroy`.

A local focus target that wants a keyboard shows the board automatically, and ending that editing hides it; a manual show survives the end of editing. Moving focus between fields keeps the board's pose, and showing a hidden board applies the configured placement. An explicit hide, the titlebar close, or the board's hide action clears visibility and blurs only the matching local target. [Input](input.md#keyboard-routing) states the routing these rules follow. The wrist menu is a separate consumer, `desktop/menu`, configured by `settings.menu`.

### Pointers and interaction

`lunette/interaction` at schema 2 makes pointers. `interaction:newPointer(owner, { seat, tuning, vibrate })` returns a pointer released with its owner or by `destroy()`, and `interaction:pointers()` lists the live ones. A pointer exposes `seat`, `tuning`, `hovered`, `hitX`, `hitY`, `distance`, `grabbed`, and `dead`, read-only. Its primitives are `hover(surface)`, `setButton { button, pressed, sink, surface }`, `focus(sink)`, `beginGrab(surface, handPose)`, `dragTo(handPose)`, `push { deflection, dt }`, `scaleWith(handPose)`, `endGrab()`, `withdraw()`, `cancel(surface, reason)`, and `vibrate { strength, duration }`. `update(input, surfaces)` drives them from one frame of input.

One frame of input is `vocabulary.Input`: `{ pose, origin, direction, trigger, buttons, grip, scrollX, scrollY, dt }`, where `buttons` maps each held `lunette.PointerButton` to true. The default mapping grips to grab and releases the grip to drop, pushes and scales a carried surface with the stick and a second grip, and otherwise picks the nearest surface within `tuning.reach`, moves and scrolls the sink under the ray, and presses each held button on the hovered sink or surface. A press focuses the pressed sink through `lunette/focus` while the provider's `focusOnPress` option is true, the default.

A surface receives pointer input through `onPointer(surface, event)`. The event kinds are `enter`, `move`, `leave`, `press`, `release`, `scroll`, and `cancel`, with the fields in `vocabulary.PointerEvent`: `pointer`, optional `x` and `y`, `captured`, and `inside`, plus a `button` on press, release, cancel, and captured move, `dx` and `dy` on scroll, and a `reason` on cancel. The cancel reasons are `tracking-loss`, `pointer-destroyed`, `surface-dead`, `surface-withdrawn`, `provider-replaced`, `hidden`, `control-removed`, `disabled`, and `grab`. A native sink receives native input rather than surface events.

A pointer captures the surface each button pressed until release or cancellation, so captured movement and release reach that surface after hover moves on. An optional `surface:project(origin, direction)` gives unbounded coordinates during capture; `raycast` stays the bounded picking test. A release carries `inside`, so a control distinguishes a release on itself from one outside. `pointer:withdraw()` cancels everything for tracking loss and ignores buttons until tracked input reports them all up. `pointer:cancel(surface, reason)` cancels one surface's gestures, and a still-held button needs a new press. A grip-driven grab cancels UI captures first. A surface with `triggerGrabbable = true` is grabbed by a primary-button press, and `surface:grabTarget()` can redirect a grab to another surface offered in the same frame, which is how titlebar buttons move their panel.

The provider's options are `tuning`, `focusOnPress`, and two hooks. `drive(pointer, input, surfaces, base)` runs for every `update`, and `base` is the default mapping. `constrain(surface, pose, base)` returns the pose a carried surface takes in every drag and scaling frame, and must return a pose. `@lunette-plugins/interaction/picking` holds `pick`, `deadZone`, and `scrollDelta` for a hook that replaces the mapping.

```lua
local interaction = require '@lunette-plugins/interaction'

return interaction.define {
  name = 'level-interaction',
  focusOnPress = false,
  constrain = function(surface, pose, base)
    local kept = base(surface, pose)
    local x, y, z = kept:getPosition()
    return lovr.math.newMat4():translate(x, math.max(y, 0.5), z)
  end,
}
```

A pointer pulses its device with `vibrate`, which forwards to the function its creator passed as `vibrate` and returns false when there is none. The laser passes its hand's controller.

`lunette/drops` is a broker for the end of a grab. `drops:onDropped(owner, { run })` hears every drop, `{ surface, pointer }`, and `drops:emit(owner, drop)` announces one. The interaction provider emits whenever a grab ends. A surface that moves a panel on its behalf, such as a titlebar, carries the panel's `kind` and `source`, so a listener finds the panel with `panels:forSource`. The desktop's pose memory, arrangement save, and arrangement exemption hear drops only here, so any replacement that carries surfaces emits a drop when a grab ends.

### Focus

`lunette/focus` at schema 2 owns one current keyboard route and the input sources that deliver to it. A target is `{ kind = 'native', seat?, sink }` or `{ kind = 'local', receiver, keymapSeat?, wantsKeyboard }`. A local receiver has `key(event)` and `text(utf8)` returning booleans and optional `onFocus(change)` and `onBlur(change)`. `wantsKeyboard` states a request; it shows nothing by itself.

```lua
local target = focus:register(owner, {
  kind = 'local',
  receiver = { key = function(event) return false end, text = function(text) return true end },
  wantsKeyboard = true,
})
target:focus()
focus:focused()       -- the current target handle, or nil.
focus:revision()      -- changes on each route transition.
target:blur()
target:destroy()
```

`register` validates and copies the target and returns a handle with `dead`, `focus()`, `blur()`, and `destroy()`. Blurring or destroying the current target leaves no route; nothing restores an older one. Focusing a native target calls `seat:setFocus(sink)` first. Native seat authority is kept per seat, independently of the one current route, so a later target on another seat leaves the first seat's focus alone. An omitted seat means `lunette.defaultSeat()`. `focus.sameNative(first, second)` compares two native targets by seat and sink identity. A host sink never calls `setFocus`. [Input](input.md#keyboard-routing) states the ordering and failure rules.

`focus:onChanged(owner, { run })` receives a frozen `{ target, revision, kind, wantsKeyboard }` after every transition, where `kind` is `none`, `native`, or `local`. The old local receiver's `onBlur` runs before the new one's `onFocus`, then listeners in registration order. A callback that changes the route again stops the remaining notifications for the superseded change.

`focus:newSource(owner, { mode })` creates a source, `virtual` by default or `physical`, with `dead`, `key(activation)`, `text(utf8, batch?)`, `keymapSeat()`, `beginBatch(id)`, `reset()`, and `destroy()`. An activation is `{ code, modifiers?, isRepeat?, batch?, physicalModifiers? }`. A local receiver sees `{ code, modifiers, source, isRepeat }`. Each delivery returns `{ kind = 'consumed' }`, `{ kind = 'unhandled' }`, `{ kind = 'refused', message }`, or `{ kind = 'failed', message }`, where `failed` means an exception already reported. Unhandled input never falls through to another target. `keymapSeat()` selects the current local target's seat, then the most recent native seat, then the first live seat. A physical source's text is accepted only within the batch it began and only while the route is unchanged. [Input](input.md#virtual-activations-and-committed-text) and [Input](input.md#physical-keypad-modes) state the text, modifier, and keypad rules.

`focus:inspect()` returns registration metadata without calling receivers.

### Lasers

`lunette/laser` makes a laser per hand: `laser:new(owner, hand, options)`, or `laser:attach(owner, options)` for each free hand. A hand has one owner at a time. A laser reads its hand's input with `readInput`, drives its pointer, and draws its beam with `draw`. `laser:update(surfaces)` and `laser:draw(pass)` do the same for every live laser, and `forHand` and `all` look lasers up. A laser's options are `seat`, `name`, `readInput`, `tuning`, `style`, `aim`, and `triggerLock`; the last four merge over the provider's.

The provider's options are `style`, `aim`, `triggerLock`, `buttons`, and the hooks `readInput(hand, base)` and `draw(laser, pass, base)`. `buttons` is a list of `{ control, button }` mapping a LÖVR controller button to a pointer button, by default the trigger to `left`, and replaces its default wholesale. `@lunette-plugins/laser/input` holds the device names and `fromHeadset(hand, headset, buttons)`. `desktop/pointing` takes `laser`, the options it attaches both lasers with, checked by `@lunette-plugins/laser/options`.

The provider smooths each laser's origin and direction with an adaptive low-pass filter before the pointer sees them. Picking, delivered coordinates, and drawing use the same filtered ray; the grab pose, buttons, and scroll are unfiltered. History resets on tracking loss, a zero ray, or a gap longer than `aim.resetAfter`. `lua/lunette-plugins/laser/aim.luau` defines the `aim` fields.

`Input.trigger` is analog pressure from 0 to 1. While pressure exceeds `triggerLock.threshold` over a live offered surface, the laser holds the previous ray, so pulling the trigger does not move the hit. Rotation past `unlockAngle` or movement past `unlockDistance` releases the hold; grip, a grab, tracking loss, a large frame gap, or the surface going away cancels it. A reader without analog pressure never locks. `lua/lunette-plugins/laser/trigger-lock.luau` defines the fields, and the [desktop guide](../guide/desktop-configuration.md#pointer-aim) describes tuning.

### Panels

`lunette/panels` at schema 3 turns windows and monitors into panels: `fromWindow(owner, window, options)`, `fromMonitor(owner, monitor, options)`, `all()`, `forSource(source)`, `onAdded(owner, callback)`, and `onRemoved(owner, { panel, run })`. A panel's options are `pose`, `width`, `height`, `priority`, `title`, `chrome`, and `curve`. A panel answers its geometry and `hidden`, `highlighted`, and `granted`.

The provider's `rendering` option is `plane` by default, which draws window and monitor textures in the scene. `layer` claims composition layers for windows and draws in the scene while a claim is not granted; monitors stay in the scene. Panels draw no border or title unless the provider's `chrome` option, false by default, or the panel's own says so; the shipped desktop's decorations are the `desktop/decorations` consumer. [Rendering](rendering.md#colour-transfer) defines colour handling.

Giving only `width` or only `height` keeps that axis and derives the other from the source's aspect ratio, recomputing it when the source's size changes. A monitor's aspect ratio comes from its oriented logical size, so a rotated output gets a portrait panel. Giving both keeps the rectangle. `panel:setSize(width?, height?)` applies the same rule.

`panel:setHidden(owner, { hidden })` sets the owner's visibility override and returns its effect; the most recent live override decides. A hidden panel is not drawn or picked and gives up its layer at once, but stays in `all` and `forSource`. `panel:close(owner)` asks a window's client to close without removing the panel, or dismisses a monitor's capture and removes its panel. `panel:destroy(owner)` is for the creating owner.

The provider requires `lunette/theme`. Its `style` option takes a `font`, `windowRadius` and `monitorRadius` in metres, and border and title fields; omitted values inherit from the theme. Scene content is clipped to the rounded corners for drawing and hits, while a granted layer stays rectangular. [Rounded scene geometry](rendering.md#rounded-scene-geometry) specifies the mapping.

A positive `curve` makes a panel part of a vertical cylinder of radius `1 / curve` centred in front of it, as `Layer:setCurve` curves a layer, with its width measured along the arc. Picking, scene drawing, and a granted layer all follow the same arc. `@lunette-plugins/panels/shape` is the pure geometry.

### Runtime themes

`lunette/theme` at schema 1 is provided by `@lunette-plugins/theme`, which takes no options. A `theme.Theme` holds `colors`, `typography`, `metrics`, and `radii` as plain data, with fonts as `FontSpec`. `lua/lunette-contracts/theme.luau` defines the fields.

`theme:current()` returns an immutable `{ revision, theme }`, and the revision increases only when the effective theme changes. `theme:select(owner, overrides)` registers a sparse override layer over the base theme, and the last live selection decides the whole effective theme. `registration:update(overrides)` replaces that layer in place; omitted fields return to the base. Disposal reveals the previous live selection or the base. Invalid overrides, including a font file that fails to load, raise and change nothing.

`theme:onChanged(owner, run)` calls `run` with a snapshot after each change, not on subscription. State commits before delivery, and a change made during delivery schedules another round instead of recursing, so intermediate revisions can coalesce. A consumer refreshes from `theme:current()` rather than trusting a retained event.

Consumers resolve appearance in the order base theme, global theme, provider configuration, and object options. Omitted fields inherit and explicit zeros remain. A palette-only change keeps pointer captures; a change of font or geometry cancels the captures it affects after the new appearance is in place.

`FontSpec` is `{ kind = 'default' }`, LÖVR's default font, or `{ kind = 'file', file, size, spread }`, a virtual-filesystem path with positive size and spread. `theme:font(spec?)` returns the face for a specification, or for the current one. The provider caches one face per specification and leaves its release to garbage collection. A plugin supplies font files through a filesystem mount, as `@lunette-plugins/theme/arcade` does with Space Mono ([Credits](../../CREDITS.md#space-mono)). In configuration, `lua/lunette-plugins/theme/descriptors.luau` describes a font as an object with a `kind` choice, supplying size 32 and spread 4 when a file font omits them.

`theme:inspect()` reports selections, subscriptions, and the revision as data.

### Theme catalog

`lunette/themes` at schema 1, provided by `@lunette-plugins/themes`, is a broker of named complete themes. It selects nothing; the `desktop/theme` selector applies a chosen entry through `lunette/theme`.

```lua
themes:register(owner, { name = 'arcade', label = 'Arcade', order = 3, theme = arcade })
```

`register` validates the complete theme and detaches it. The name and label are non-empty strings, `order` is a finite number defaulting to 0, and a name held by a live registration raises. `list()` returns frozen `{ name, label, order, theme }` entries sorted by order and then name, `get(name)` returns one, and `onChanged(owner, { run })` runs after each registration begins or ends. `@lunette-plugins/theme/standard` registers `dark` and `light`, and `@lunette-plugins/theme/arcade` registers `arcade`; each provides nothing, so disabling one removes only its themes.

### UI panels

`lunette/ui` at schema 2 makes owner-scoped flat VR panels with controls: `newPanel(owner, options)`, `newTitlebar(owner, name, surface, options, visible?)`, and `panels()`. `@lunette-plugins/ui` implements it, requiring focus, surfaces, theme, and frame, and takes `theme`, `titlebarStyle`, and `draw` options. It offers each visible panel as a surface. The consumer draws its panels in its chosen frame phase. The [UI guide](../guide/ui.md) has an example.

A panel declares a unique `name`, `width` and `height` in metres, and `logicalWidth` and `logicalHeight`, and optionally a pose, visibility, grabbability, a `grabTarget` surface that grip moves instead of the panel, theme overrides, a draw hook, and `titlebar` options. Logical coordinates start at the top-left with y increasing downward. Control bounds are half-open rectangles. Input, drawing, and descriptions use the same declared geometry, clipped to the panel. Higher `z` wins an overlap, then later registration.

`titlebar` options, or `panel:setTitlebar(options?)`, give a panel the shared titlebar: a `title`, optional `onClose` and `closeId`, extra `actions`, `style` overrides, and `draggable`. Closing calls `onClose` and hides nothing by itself. The bar sits outside the body and joins it through [a frame attachment](#joined-frame-attachments) when the body is eligible. Trigger on the bar outside its buttons drags the target; grip on a button moves the owning surface. Other surfaces use `newTitlebar` and call its `sync`, `draw`, `update`, and `destroy`. The desktop's decorations, manager, expanded wrist menu, and keyboard display use this titlebar.

Panels create buttons, text fields, choices, lists, and regions through owner-scoped methods. A control id is unique per creation owner across the provider's live panels, so different owners may reuse an id. A control has bounds, a label, enabled state, `z`, theme overrides, a draw hook, and `exclusive`. Buttons call `onActivate()`. Choices and lists name items by string id. A region receives `vocabulary.PointerEvent`s and may register a local focus receiver.

A pointer button captures the control it pressed until release or cancellation. A release activates only that control, and only inside it; cancellation never activates. An exclusive control refuses a second pointer while held. Hiding, disabling, destroying, resizing, or replacing bounds or items cancels the affected captures. `Panel:setPose` keeps captures during rigid motion. Hover does not take keyboard focus.

A text field holds valid single-line UTF-8. `setSelection(caret, anchor?)` and `selection()` use one-based byte offsets at grapheme boundaries from [`lunette.textBoundaries`](#text-boundaries). A user edit calls `onChange` after validation, Enter calls `onSubmit` when validation passes, and Escape blurs and calls `onCancel`. `setValue` calls nothing.

A UI panel resolves the global theme, the provider's `theme`, the panel's, and each control's, in that order. `ui.Theme` carries a native `Font`; override types take a `FontSpec`. Colours replace as whole lists. A draw hook receives `(pass, visual, base)`, where `visual` is an immutable snapshot in logical coordinates, and calls `base` to keep the wrapped drawing. Provider, panel, and control hooks wrap in that order. Each hook invocation restores pass state and transforms, including on error; a hook keeps within `visual.clip`, balances its own stack operations, and does not retain the pass or the borrowed font. Draw errors propagate to the frame boundary, and widget callback errors are reported with the control owner. `lua/lunette-plugins/ui/depth.luau` owns the depth offsets that separate backing, controls, contents, and glyphs.

Panels and controls end with their creation owners, with the provider, and at source reload. A control's focus target is registered under the UI provider and held by the control. `panel:describe()` returns detached geometry, controls, visibility, a revision, and a `ui.Generation` token shared by panels from one provider activation. `Control.owner` is a `ui.OwnerIdentity` token, fresh for each creation-owner activation. The generation token, owner token, and id together identify a live control; descriptions grant no authority.

### Bindings

`lunette/bindings` is a broker for key chords. `bindings:register(owner, { chord = { key, modifiers }, run })` binds a LÖVR key name with exactly the named modifiers from `bindings.MODIFIERS`, `control`, `alt`, `logo`, and `shift`. A chord, in any modifier order, names one registration, and binding a bound chord raises. A matching press runs `run(press)` and is consumed; a repeat is consumed without running again, and a raising `run` still consumes.

```lua
bindings:register(owner, {
  chord = { key = 'h', modifiers = { 'control', 'alt' } },
  run = function(press) end,
})
```

The provider requires `lunette/frame` and takes presses in the `binding` phase, reading held modifiers through `@lunette-contracts/keys`' `heldModifiers`, so a bound press never reaches a client. `desktop/input` delivers in the `delivery` phase and does not require bindings. The shipped desktop binds no chords; reload is the `desktop/reload` menu action.

### Menu actions

`lunette/menu` at schema 1, provided by `@lunette-plugins/menu` without options, holds actions and renders nothing. `register(owner, action)` takes `id`, `label`, `run`, and optional `group`, `order`, `enabled`, and `selected`, defaulting to `''`, 0, true, and false. A duplicate id raises.

`list()` returns frozen descriptors sorted by group, order, and id, each with the resolved values and a `registration` token. `update(owner, effect, { enabled?, selected? })` changes the owner's own live registration. `invoke(id, registration?)` returns `{ kind = 'invoked' }`, `{ kind = 'unavailable' }` for a missing, disabled, or replaced action, or `{ kind = 'failed', message }`. Passing the descriptor's token keeps a stale row from invoking a replacement with the same id. `run` executes under the registering owner's protected context.

### Layouts

`lunette/layouts` is a broker of named layouts, provided by `@lunette-plugins/layouts`. A layout is a function that poses the panels a caller passes; it holds no panels or tags.

```lua
layouts:register(owner, { name = 'grid', apply = function(panels, options) end, continuous = false })
layouts:apply { name = 'grid', panels = tag:panels(), options = { columns = 3 } }
layouts:names()            -- { 'arc', 'grid' }, sorted
layouts:get 'grid'         -- { name = 'grid', continuous = false }, or nil
layouts:onChanged(owner, { run = function() end })
```

A name names one live registration, and registering a taken name raises. `apply` calls the named layout with the live panels, in order, and the options. It raises for an unknown name, listing the known ones, and lets the layout's own errors through. A panel is `vocabulary.Movable`, posed with `panel:setPose(pose)`. `continuous` marks a layout the consumer applies every frame; the broker applies nothing itself. `onChanged` runs after each registration begins or ends.

`@lunette-plugins/layout/arc` registers the arc layout and provides nothing. Its options are `layout`, the name it registers, default `arc`, and `tuning`: `radius`, `step`, the minimum angle between neighbours, `span`, the widest angle, `gap`, the edge spacing in metres, and `center`, a vector. Options passed to `apply` are a partial tuning merged over the configured one. Panels face the centre from a circle of `radius`, spaced so neighbouring flat panels do not intersect; when the arc would exceed `span`, every separation shrinks by one factor. `arc.layout(tuning, label)` is the layout function and `@lunette-plugins/layout/arc/geometry` the pure geometry.

### Tags

`lunette/tags` groups borrowed panels under names. `tags:hold(owner, { name, index, selected, layout })` returns the named tag and an effect, creating the tag when none exists; the options apply only at creation. A tag lasts while any owner holds it. `tags:find(name)`, `tags:all()` in index order, and `tag:panels()` read it.

```lua
local tag = tags:hold(owner, { name = 'web' })
tag:add(owner, panel)
local kept = tag:exclude(owner, { panel = panel })
tag:setSelected(owner, { selected = true })
tag:setLayout(owner, { layout = 'grid' })
tags:onChanged(owner, { tag = tag, run = function(change) end })
```

A panel is a member while some owner holds its membership and no owner excludes it. `exclude` returns an effect, so the panel returns when the excluding owner lets go; this is how a plugin moves a window another plugin placed. `remove` drops the caller's own membership and raises when another owner holds it. Selection and layout are owner-held overrides, and the most recent live one decides. A layout is a name in the layouts broker or nil; tags do not resolve it.

`onChanged` hears every tag, or the one `tag` names, as `{ tag, kind }` with `kind` one of `created`, `destroyed`, `selection`, `layout`, and `membership`, after the change. A panel that dies leaves its tags silently, because `panels:onRemoved` announces it.

### Rules and placement

`lunette/rules` holds rule sources and resolves a window's properties from them. `rules:addSource(owner, { name, precedence, resolve })` registers a source, and `rules:setRules(owner, { name, precedence, rules })` validates a rule list and registers it as one source, by default `lunette.rules` at the provider's precedence. Higher precedence merges later and wins. `vocabulary.PRECEDENCE` names `rules` at 100, `persisted` at 200, and `native` at 300, so a configuration places its own source relative to them.

A rule's `match` takes named window fields, each a value or a predicate of the field and the window, and `where`, a predicate of the whole window. The named properties are `pose`, `width`, `height`, `title`, `priority`, `chrome`, `curve`, `hidden`, `adopt`, and `tags`, each a value or an evaluator; other keys pass through to the resolved properties.

`lunette/placement` turns a window into a panel and is the one component that depends on rules, panels, and tags. `placement:place(owner, { window, properties, defaults })` resolves properties through rules unless given, fills gaps from `defaults`, makes the panel, applies `hidden`, joins and holds the named tags, and returns the panel, properties, and effect. Disposing the effect, the owner unloading, or the panel's removal ends the placement. `placement:placed()` lists live placements and `placement:onPlaced(owner, { run })` hears each new one, whoever made it.

The placement provider's `panelOptions(properties, window, base)` hook returns the panel's options; `base` maps `pose`, `width`, `height`, `title`, `priority`, `chrome`, and `curve`. A configuration that forwards a property of its own replaces only this hook:

```lua
local placement = require '@lunette-plugins/placement'

return placement.define {
  name = 'bending-placement',
  panelOptions = function(properties, window, base)
    local options = base(properties, window)
    if type(properties.bend) == 'number' then
      options.curve = properties.bend
    end
    return options
  end,
}
```

`lunette/adoption` places windows automatically. `adoption:install(owner)` registers the rules source `lunette.adoption` on the caller's owner, at the provider's precedence, answering the pose a window carries in its `lunette.pose` property. `adoption:start(owner, { defaults, filter })` places every window unless `filter` returns false or its resolved properties carry `adopt = false`.

### Errors stream

`lunette/errors`, provided by `@lunette-plugins/errors`, subscribes to `lunette.onError` for its activation and rate-limits the reports. `errors:subscribe(owner, { run, cleared })` hears each delivered report, `errors:recent()` returns the bounded history oldest first, and `errors:clear(owner)` empties it and calls each `cleared`. A report is `{ message, traceback, suppressed, text, sequence }`: `suppressed` counts identical reports withheld since the last delivery, `text` is ready to show, and `sequence` counts deliveries since start or clear. The options are `window`, the seconds a repeat is withheld, `maxKeys`, `history`, and `clock`. A report raised while subscribers run, such as a subscriber's own error, enters the history without being delivered. `@lunette-plugins/errors/limiter` is the pure half.

A presenter is any subscriber. The shipped `desktop/errors` draws the latest report on a quad, and `examples/desktop/notify-errors.luau` sends desktop notifications.

### Frame pacing and output scale

How often each window's client draws and which scale each output's clients render at are policy over `window:setFrameRate` and `output:setMode`. Each is a contract that hands out a pure chooser, and a desktop entry reads the scene and applies the answers.

```lua
local pacer = pacing:newPacer()
local rate = pacer:observe { visible = false, contentType = window.contentType, drew = true }

local chooser = scale:newChooser()
local step = chooser:choose(0.8)   -- the scale for a panel 0.8 metres away.
```

`lunette/pacing` hands out a pacer per window. `observe { visible, contentType, drew }` returns a rate in hertz, or nil for unthrottled. `drew` reports whether the client committed since the last observation, and omitting it adds no sample. A window is exempt when its content type is exempt or when at least the `busy` fraction of recent samples drew. A visible window is unthrottled; a hidden exempt one runs at `exempt`, and any other hidden one at `background`. The tuning fields are `background`, default 1 Hz, `exempt`, default 30 Hz, `history`, default 90, `busy`, default 0.5, and `exemptTypes`, by default `video` and `game`. `@lunette-plugins/pacing/pacer` is the pure rule.

`lunette/scale` hands out a chooser per output. `choose(distance)` returns a rung of `lunette.scaleSteps()` for the nearest panel showing the output's clients. The ideal scale is `reference / max(distance, nearest)`. The first choice is the largest rung at most the ideal; afterwards the chooser climbs only when the ideal passes a rung by the `raise` fraction and descends only when it falls below the current rung by the `lower` fraction. The tuning defaults are `reference` 1 m, `raise` 0.06, `lower` 0.12, and `nearest` 0.05 m. The ladder is fixed, so a raised panel asks the layer pool for a rung it already holds. `@lunette-plugins/scale/chooser` is the pure rule.

Pacers and choosers hold no resources. `desktop/pacing` and `desktop/scale` apply them each frame; [Default configuration](stdlib.md#default-configuration) states what they read.

## Text boundaries

`lunette.textBoundaries(text)` returns a fresh array of one-based byte offsets at extended grapheme cluster boundaries, starting with 1 and ending with `#text + 1`; the empty string returns `{ 1 }`. Invalid UTF-8 raises. `crates/lunette/src/lua/text.rs` implements it with `unicode-segmentation`. It provides segmentation only, with no shaping, bidirectional layout, normalization, or IME support.

## Events

Native events travel LÖVR's event queue, so they interleave with `lovr.keypressed` and the other LÖVR callbacks in a defined order. A listener subscribes through a module function, which returns the function that cancels it:

```lua
local cancel = lunette.onWindowOpened(function(event)
  print(event.window.title)
end)
```

The events are `onWindowOpened`, `onWindowClosed`, `onTitleChanged`, `onMonitorAdded`, `onProcessExited`, `onProcessOutput`, `onLayerGranted`, `onLayerRevoked`, and `onError`. Listeners run in subscription order, each under a protected call, and one that raises does not stop the rest. Every payload is a table. `crates/lunette/src/events/mod.rs` declares each event once, and the subscription function and payload type are generated from it, so a handler's parameter is typed without an annotation.

An event is delivered against the snapshot of the frame it was drained in, so `onWindowClosed` hands over a dead handle that still reports the window's last title, size, and id. `onProcessExited`'s `outcome` is `exited`, `signalled`, or `spawnFailed`, and says which of `code`, `signal`, and `message` is present; a program that never started is reported only this way.

Source reload clears every native subscription. A plugin subscribes through `Context:on`, which ends the subscription with the activation ([Confinement](#confinement)). Finer notifications, such as the panels contract's `onAdded` and `onRemoved`, are built in Lua by providers.

## Handles

Window, monitor, process, seat, output, and claim handles are persistent objects with stable identity, refreshed at frame start. [Architecture](architecture.md#handles) describes the model and why dead handles go inert rather than raising. Reads are snapshot fields; mutations are requests.

```lua
print(win.title)             -- last frame's value.
print(win.appId)             -- the client's application identifier.
print(win.width, win.height) -- the committed size in pixels.
print(win.opaque)            -- true when the buffer's fourth component is padding.
print(win.contentType)       -- 'none', 'photo', 'video', or 'game'.
print(win.output)            -- the output the client is shown, or nil.
print(win.commit)            -- changes on each new buffer; 0 before the first.
win:resize(1920, 1080)       -- a configure request.
win:setFrameRate(10)         -- how often this client may draw; nil for unthrottled.
win:close()                  -- a close request.
win:getTexture()             -- this frame's pixels; never cache it.
win:stabilize()              -- a persistent texture, copied on each damaged frame.
win:setProperty('pose', p)   -- keeps a value for this window across a reload.
```

`win:close()` sends the xdg-toplevel close request, which the client may answer with a prompt or ignore; the window goes when the client unmaps it. `win:resize(width, height)` configures the toplevel with whole pixel counts of at least one, and `width` and `height` change when the client commits, possibly at another size. Every mutation returns `false` on a dead handle.

`win:setFrameRate(hz)` sets how often the compositor answers the window's frame callbacks, which is how often the client draws. `nil` restores unthrottled, the starting state. The rate is a finite positive number, and a rate below about 1 Hz is paced at 1 Hz, because a client that receives no frame callbacks stops answering input. [Rendering](rendering.md#frame-pacing) states the rest, and [Frame pacing and output scale](#frame-pacing-and-output-scale) states the policy.

`win:stabilize()` is described in [Rendering](rendering.md#windowstabilize). `win.opaque` reports that the current buffer has no alpha channel; [Rendering](rendering.md#alpha) states how a consumer uses it.

`win.contentType` is the `wp_content_type_v1` hint, which clients report unevenly. `win.commit` comes from a counter every surface shares and never reuses, so a caller that reads it each frame learns whether the client drew. The pacer combines the two. `win.output` is the output the client was spawned with or the starting output, and nil for a handle never seen in a snapshot.

## Per-window properties

The native property store keeps values per window outside the Lua state, so they survive source reload:

```lua
win:setProperty('pose', '0 1.6 -1.5')  -- a number, a string, a boolean, or nil to remove.
win:getProperty('pose')                -- what was kept, or nil.
win:properties()                       -- { pose = '0 1.6 -1.5' }, a fresh table each call.
```

A value is a number, a string, or a boolean; a table or a non-finite number raises, naming the key. `setProperty` returns `false` on a dead handle. `getProperty` still answers on a dead handle, so an `onWindowClosed` handler can read what the window stored. `properties()` lets a configuration rediscover keys it computed. Entries live as long as the window: a reload leaves them and closing the window drops them. Writing them to disk is a configuration's or library's choice.

`win.id` is stable for the window's life, across source reload and hard restart, because the compositor thread survives both ([LÖVR integration](lovr-integration.md#restart-semantics)). A hard restart replaces the Lua state, so values that must survive it belong in the property store or in data keyed by a durable identity such as `win.appId`.

## Outputs

An output is a virtual monitor that lunette shows to the clients assigned to it. It is neither one of the user's screens, which are monitors, nor a panel.

```lua
local out = lunette.newOutput { width = 1920, height = 1080, scale = 1.5, refresh = 90 }
local steps = lunette.scaleSteps()   -- the scale ladder, ascending.

for _, output in ipairs(lunette.outputs()) do
  print(output.id, output.dead)
  print(output.width, output.height, output.scale, output.refresh)
  output:setMode { scale = 2 }       -- unnamed fields are kept.
  output:destroy()
end
```

`newOutput` returns a handle before the compositor creates the output, so `dead` is true in that frame, as with `newSeat` and `spawn`. `width` and `height` are required whole pixels; `scale` defaults to 1 and `refresh` to 60 Hz, and each must be finite and positive. Refresh is in hertz above the native boundary and is advertisement only; `window:setFrameRate` controls pacing. Clients reallocate on a mode change, and some do so expensively, which is why the scale chooser moves in hysteretic steps.

`lunette.scaleSteps()` returns the scale ladder as a fresh table. It is the ladder claimed layer sizes are quantised to ([Rendering](rendering.md#the-layer-pool)), so raising a panel's scale asks the pool for a size it already holds.

`lunette.spawn { output = out }` assigns a client an output for its life. A running client cannot move, because the change would reach it as a monitor unplugged and replugged; changing the output's mode is the supported operation. A session starts with one output, which every unassigned or externally started client sees. It cannot be destroyed. Destroying another output moves its clients to the starting output, which they see as an unplug and a plug. Transform and physical size are not settable; the physical size follows the mode so a client's density estimate agrees with the scale.

## Monitors

`lunette.monitors()` returns the user's own screens, captured directly through `wlr-screencopy` when available and through the screencast portal and PipeWire otherwise.

```lua
for _, monitor in ipairs(lunette.monitors()) do
  print(monitor.id)                                  -- the saved identity.
  print(monitor.name)                                -- 'Acme X24 on DP-1'.
  print(monitor.width, monitor.height)               -- the host mode, in pixels.
  print(monitor.x, monitor.y)                        -- logical position.
  print(monitor.logicalWidth, monitor.logicalHeight) -- oriented logical size.
  print(monitor.mirrored, monitor.pending, monitor.directCapture)
  print(monitor.frameTransform)                      -- the texture's UV transform, or nil.
  monitor:getTexture()                               -- latest pixels, or false; read each frame.
  monitor:mirror()                                   -- request capture.
  monitor:setPaused(true)
  monitor:dismiss()
end
```

The list is ordered by identity. `monitor.id` is described in [Host desktop](host-desktop.md#identity-and-lifecycle). `width` and `height` are the host mode, not the texture size. A monitor sink takes pixel coordinates over the mode and maps them into the logical rectangle.

`monitor:mirror()` requests capture, trying direct capture first and the portal only when needed; the portal may show a dialog. `pending` reports an outstanding request and `mirrored` an installed stream, which may not have produced pixels yet. Direct capture has no asynchronous failure channel, so `mirrored` does not prove frames still arrive. `mirror` returns `false` when the monitor is gone or setup is refused. A source reload keeps streams the new configuration requests again and stops the rest.

`lunette.selectMonitors()` requests a fresh portal grant and returns `(true, nil)` or `(false, message)`. `lunette.monitorSelection()` returns `{ state, message? }` with `state` one of `idle`, `pending`, `ready`, and `failed`. Existing captures continue while a selection is pending or refused, and a successful grant replaces PipeWire streams while leaving direct streams alone. A refused portal request stays refused until the next explicit selection.

`monitor:getTexture()` is valid for the current frame only. `monitor.frameTransform` is nil without a frame, and otherwise one of `undefined`, `normal`, `rot90`, `rot180`, `rot270`, `flipped`, `flipped90`, `flipped180`, and `flipped270`; built-in panels apply it. `monitor:dismiss()` removes the active mirror and its texture, keeping the portal session; a direct capture worker may stay detached. `monitor:setPaused(paused)` pauses PipeWire and does nothing for direct capture. Captured pixels include the cursor when the backend embeds it.

`lunette.onMonitorAdded` fires for each monitor at startup and for each one attached later, carrying `id` and, while still attached, `monitor`.

## Sinks and input domains

A sink is a target for pixel-space input. `window.sink` reaches a hosted client and `monitor.sink` the host desktop, and the two behave differently:

```lua
print(sink.domain)             -- 'window' or 'host'.
print(sink.window, sink.monitor, sink.id)
sink:pointer(x, y)             -- pixel coordinates on the target.
sink:button('left', true)      -- press; false releases.
sink:leave()                   -- the pointer stops hovering; focus is untouched.
sink:scroll(dx, dy)            -- a continuous distance, in surface pixels.
sink:scrollDiscrete(dx, dy)    -- whole wheel notches.
sink:key(keycode, true)        -- an evdev keycode; false releases.
sink:modifiers { 'shift' }     -- the modifiers held from now on.
sink:typeText('café')          -- text, whether or not the layout can express it.
```

A window sink delivers through a seat, so each seat has its own cursor and focus. A host sink delivers to the user's desktop, where every host sink shares one cursor and one keyboard focus; [Host desktop](host-desktop.md#the-input-domain-leak) explains why that is exposed. Every method takes an optional trailing seat, defaulting to the starting seat; a host sink ignores it.

Coordinates are pixels on the window's committed size or the monitor's mode, and a non-finite coordinate raises. Every method returns `false` on a dead handle. `monitor.sink` exists whether or not the monitor is mirrored. `sink:leave()` withdraws hover without changing keyboard focus and returns `false` on a host sink. The two scroll methods stay separate because clients scroll kinetically only for continuous input; a host sink converts both to wheel detents.

`sink:key(keycode, pressed)` sends an evdev keycode to the seat's focused client, or to whatever the host focuses for a host sink, which refuses codes its input provider did not declare. `lunette.keyCodes()` returns a fresh table from camelCase key name to code, typed by `lunette.KeyName`; the names are the host sinks' `VirtualKey` set in `crates/lunette-capture/src/hid/key.rs`. `sink:modifiers(names)` replaces the held modifiers with names from `lunette.modifierNames()`, and `lunette.lockingModifierNames()` lists the toggling ones, `capsLock` and `numLock`. A host sink refuses `mod3`.

`sink:typeText(text)` types text the layout can express directly and otherwise uploads a temporary keymap, types against it, and restores the client's keymap, splitting long text into runs. It must not be interleaved with `sink:key` on the same seat. A host sink refuses it.

## Seats

A `wl_seat` carries one pointer and one keyboard, so two cursors need two seats ([Input](input.md#seats)).

```lua
local left = lunette.newSeat('left', { layout = 'de', repeatDelay = 200, repeatRate = 50 })

for _, seat in ipairs(lunette.seats()) do
  print(seat.id, seat.name, seat.dead)
  print(seat.modifiers)          -- names, as last sent to clients.
  print(seat.layouts)            -- an array of one: 'English (US)'.
  print(seat.clipboardBridge)
  seat:setFocus(win.sink)        -- gives this seat's keyboard to a sink; nil withdraws it.
  seat:setModifiers { 'shift' }
  seat:symbolFor(30)             -- the keysym a keycode produces, or nil.
  seat:characterFor(30, { 'shift' })
  seat:strokeFor('A')            -- { keycode = 30, modifiers = { 'shift' } }, or nil.
  seat:setClipboardBridge(true)
  seat:destroy()
end
```

`lunette.defaultSeat()` returns the seat a native input call uses when its seat is omitted, or nil when that seat is absent from the snapshot. Each call returns a fresh handle, so identity comparisons use `seat.id`.

`lunette.newSeat(name, options)` returns a handle that is dead until a snapshot contains the seat. A name already taken by a live or pending seat raises; `seat:destroy()` releases the name immediately. The options are libxkbcommon's `rules`, `model`, `layout`, `variant`, and `options`, plus `repeatDelay` in milliseconds and `repeatRate` per second, defaulting to 200 ms and 50 Hz; a rate of zero disables repeat. An absent layout name inherits the `XKB_DEFAULT_*` variables. A seat carries one layout: an explicit `layout` naming several is refused and the seat never appears, while an inherited list is narrowed to its first entry with a log message. A layout that fails to compile is logged and the seat never appears. [Input](input.md#decisions) records why.

`seat:setFocus(sink)` gives a client the keyboard; nothing infers focus from pointer motion. A host sink returns `false`, because the host compositor owns host focus. `seat.layouts`, `symbolFor`, `characterFor`, and `strokeFor` answer from the seat's layout, which is what lets a virtual keyboard draw legends and produce keycodes without reimplementing xkb. `strokeFor` takes one character or a keysym number, prefers the fewest modifiers and then the lowest keycode, and returns nil for what the layout cannot express.

Exactly one seat bridges the host clipboard and primary selection, the starting seat by default. `seat:setClipboardBridge(true)` moves the bridge to that seat; `false` on a seat that does not hold it does nothing. A selection the seat already held crosses only on the next copy. [Input](input.md#clipboard) states the mapping.

`seat:destroy()` withdraws a published seat or cancels a pending one, and returns `false` for the default seat or a seat already gone.

## Layer claims

A panel renders as an in-scene quad or on a backend-owned composition layer, which is sharper because the backend samples the source at its native resolution. Layers are scarce, so a panel claims one:

```lua
local claim = lunette.claimLayer {
  window = win,
  width = win.width,           -- the requested size, in whole pixels.
  height = win.height,
  priority = 10,
}

print(claim.granted)           -- whether it holds a layer this frame.
print(claim.layer)             -- the LÖVR Layer, or false; never cache it.
print(claim.width, claim.height) -- the layer's size, not the request.
claim:setPriority(20)          -- takes effect at the next frame boundary.
claim:release()
```

`claim.layer` is LÖVR's own `Layer`. The host sorts claims stably by priority and grants the top ones; any ranking policy is a different number, and a NaN priority raises. Requested sizes are quantised up to the ladder ([Rendering](rendering.md#the-layer-pool)). Grants and revocations land on frame boundaries, never between `lovr.update` and `lovr.draw`, so a fresh claim holds nothing in the frame that made it, and the in-scene quad is always available.

`lunette.onLayerGranted(function(event) end)` receives `event.claim` and `event.layer`, and `lunette.onLayerRevoked` receives `event.claim`, both at the boundary before `lovr.update`. A revoked claim stays live and is granted again when a layer frees. A claim is dead only after `claim:release()`. Nothing releases a claim when its handle is collected, because event payloads carry other handles to the same claim, so a configuration that drops a panel releases its claim.

## Scene rendering

```lua
lunette.setSceneEnabled(false)   -- skip lunette's own scene rendering.
print(lunette.sceneEnabled())    -- what was last asked for.
```

When every panel is on a layer, drawing the scene costs a render pass and resolve for nothing. With the scene disabled, `lovr.draw` is not called and the scene is left out of the frame; the headset frame and the composition layers are still submitted. The change applies at the next frame boundary, and the value survives source reload. Everything drawn in `lovr.draw` belongs to the configuration, so lunette cannot decide this. The default is on, and nothing shipped turns it off. [Rendering](rendering.md#frame-pacing) records what an idle frame still costs.

## Reload

Source reload and hard restart keep running applications. Plugin instance reload is separate and replaces one activation.

`lunette.reload()` performs a source reload in the current Lua state, in this order: it shuts down plugin runtimes and retires the contract epoch, clears native event subscriptions, clears the configuration's LÖVR callbacks and `lovr.lun*` handlers, removes unprotected entries from `package.loaded`, and runs `main.luau` and then `lovr.load` with the startup `arg`. The LÖVR modules, XR session, GPU objects, compositor, clients, globals, and the Lua state remain. `crates/lunette/src/reload.rs` lists the protected `package.loaded` roots and the cleared callbacks, which exclude the defaults `boot.lua` installs once per state. Plugin effects are the only cleanup a reload runs; a module that holds resources outside a plugin keeps them.

`lunette.reload()` returns `true`, or `false` and a message, and never raises. A reload that fails after `main.luau` starts leaves whatever the failed run installed, and the user can fix the file and reload again; safe mode is only for startup. A reload requested during a reload or from inside a plugin callback is refused.

`lunette.restart()` performs a hard restart through `lovr.event.restart`, closing and rebuilding the Lua state with graphics and the XR session ([LÖVR integration](lovr-integration.md#restart-semantics)). The restart is taken after the frame's callbacks return, so several requests in one frame are one restart. The host shuts down plugin runtimes and clears native subscribers before the state closes, whichever way the restart was requested. Modules that allocate native objects outside the plugin runtime get no cleanup.

Wayland clients survive both because the compositor owns the socket outside the Lua state.

## Errors

Three kinds of callback run under a protected call: `lunette.on*` listeners, plugin initializers and inverses, and handlers that a Lua dispatcher protects and reports through `lunette.reportError`. An error in one is logged with its traceback and sent to every `lunette.onError` listener, and execution continues with the next listener, drain step, or handler. `crates/lunette/src/callback_error.rs` is the native boundary; it does not rate-limit. The error stream provider rate-limits for its presenters ([Errors stream](#errors-stream)).

`lunette.reportError { context, message, traceback? }` reports through the same boundary, with `context` leading the message. A missing field or an unknown one raises. The frame, surfaces, and panels providers report each raising handler this way, so one handler's error does not stop the error display that draws after it. A plugin failure during a drain is reported with a context such as `plugin load: <definition> (instance 3)`. An instance waiting for a provider is logged, not reported.

LÖVR's own callbacks are not protected by the host. An error in `lovr.update` or `lovr.draw` unwinds to `boot.lua`'s handler, which without a `lovr.errhand` ends the process with status 1. The shipped configuration binds its callbacks through the frame provider, which protects every handler. A configuration that assigns `lovr.update` or `lovr.draw` itself protects its own body. [Known gaps](#known-gaps) records this.

The native layer owns one recovery path: if `main.luau` fails to load, safe mode starts. The trigger wraps `lovr.boot`, which raises for a source that will not mount, a missing `main.luau`, a raising `conf.luau`, a syntax error, an error at the top level of `main.luau`, and an error in `lovr.load`. Safe mode replaces whatever callbacks the failed configuration installed and shows the load error on a panel, with a laser, a terminal launcher, and a reload key. `crates/lunette/src/safe_mode.luau` is compiled into the binary and requires only `lunette`. It tries `foot`, `weston-terminal`, `alacritty`, `kitty`, `konsole --separate`, and `xterm` in order, advancing only on a spawn failure of the current attempt.

## lunctl

`lunctl` sends a Lua chunk to the running session over the Unix socket `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600, inside a directory lunette creates at 0700. The session evaluates the chunk on the Lua thread between frames within a time budget and sends the result back.

The directory is what enforces the permission: a socket inode is created with `0777 & ~umask`, `fchmod` on a socket descriptor does not reach the inode, and loosening permissions after `bind` leaves a window for a connection. `$XDG_RUNTIME_DIR` is checked for the same property at startup.

```console
$ lunctl 'return #lunette.windows()'
3
$ lunctl 'for _, w in ipairs(lunette.windows()) do print(w.appId, w.title) end'
$ lunctl "return require('@lunette-contracts/vocabulary').encodePose(lovr.math.newMat4())"
```

A chunk resolves a free name from the globals and then from loaded modules, trying the name as written and then under `@`, so `lunette` finds `@lunette`. A name the chunk assigns becomes a global for later chunks. Like awesome-client, `lunctl` takes a chunk as an argument, on standard input, or at an interactive prompt; `rlwrap lunctl` adds line editing, and `--socket PATH` names another socket.

The exit status is `0` when the chunk ran, `1` when it raised, `2` when it did not compile, `3` when it exceeded its budget, `4` when its result cannot be represented or exceeds one message, `5` when the session did not evaluate it, `6` when the session cannot be reached, and `64` for wrong usage, including an oversized chunk. A top-level string prints without quotes, and a handle prints as its kind and identity, such as `<window 3>`.

`LUNETTE_CONTROL=off` disables the socket. Unset, empty, or `on` enable it, and any other value disables it with a warning. There is no network transport. `lunctl` has the access of the user's session, which is why the socket is restricted and deliberate.

## Language binding

The API is bound with `mlua`, which creates the session's Luau state and owns it for the session. LÖVR steps the same state through the raw C entry points. Luau has no FFI, so a configuration reaches native code only through the standard library and `lunette`. The API is available only in the main Lua state, not in `lovr.thread` or `lovr.task` states.

## Decisions

### mlua on Luau

A Lua mistake must raise a catchable error rather than crash the window manager, and mlua's per-call cost is negligible beside a compositor frame. Luau lets the standard library and configurations be statically checked, which catches a local used before its declaration and an accidental global. LuaJIT is not a build mode, because the standard library's annotations do not parse there.

### Control socket over Lua eval

awesome's remote Lua evaluation is a large part of its usability, and `lunctl` keeps it with a 0600 Unix socket instead of the session D-Bus, an explicit switch, and full serialisation. The plugin API is an in-process composition mechanism and does not narrow the remote protocol.

### LUNETTE_CONTROL fails closed

Only an unset, empty, or `on` value enables the socket. An unrecognised value is most likely a misspelt `off`, and opening a socket that evaluates arbitrary Lua on a warning nobody reads was rejected. A typo costs a `lunctl` that visibly does not connect.

### The lunctl time budget is best-effort

A chunk runs under a Luau interrupt callback that raises once the deadline passes, at the next safepoint. A `pcall` in the chunk can catch it, and a loop in native code never reaches a safepoint. A hard bound would need a watchdog that aborts the process, which takes every client with it, so it is not built.

### lunctl refuses what it cannot represent

The serialiser errors on functions, coroutines, foreign userdata, non-scalar keys, and cycles, naming the path, rather than falling back to `tostring`, which is the defect in awesome's remote control. Shared subtables are duplicated and a node cap bounds the result. Traversal is raw, so metamethods cannot change what is reported. A reply too large for one message is reported as `Reply::Oversized` rather than by closing the connection, which the client would misreport as an unreachable session. A handle serialises as its kind and session identity, never an address.

### The plugin types are local

Each capability carries its own service type, and each definition its configuration type. A mapped `Services<R>` and `Provisions<P>` design needs a recursive type for the whole provider graph, which exceeds Luau's normalization budget even for an empty initializer. Raising Luau's limits was rejected. Runtime declarations and lifecycle checks validate wiring; the checker does not claim whole-graph guarantees.

### Per-window state lives in a native store

Source reload recreates configuration locals, but a pose or size placed by hand cannot be derived again. The native store lives outside the Lua state, keyed by window id, and holds scalars only; a caller that needs structure encodes a string. Serialising arbitrary Lua values across reload was rejected because it fails on functions, coroutines, and handles.

### Safe mode is compiled in

Safe mode exists for a `main.luau` that fails to load, and a broken installation is one cause, so it reads nothing from disk and requires only `lunette`. It solves its own ray-plane intersection rather than using the panels provider; the duplication is the price of always working, and both sites say so. Installing it as a file under `$SYSCONFDIR` was rejected because it fails in exactly that case. It is a `.luau` file embedded with `include_str!` so it stays readable and diffable. Safe mode wraps `lovr.boot` rather than defining `lovr.errhand`, because `lovr.boot` is the boundary whose failure means the configuration did not start, and `lovr.errhand` belongs to the configuration.

### The declarations are generated from the registration

`lua/lunette/init.luau` is what the checker reads for `require '@lunette'`, because Luau resolves a require to a file and a definitions file declares only globals. Each member is declared once beside its Rust closure, and `LuauType` derives its Luau spelling from the Rust type, so the declaration cannot drift from the registration. A hand-written stub was rejected because nothing would check it.

### An event is subscribed to, not assigned

An event has two kinds of listener, the configuration and the libraries it loads, and an assigned callback gives each event one slot, forcing a library to poll or to chain the displaced handler. A module function also types its handler, which a callback on the `lovr` global cannot. Assigned `lovr.lun*` callbacks and assignment on the module table were rejected because both keep the single slot. The cost is a second callback convention beside LÖVR's frame callbacks, which have one owner.

### A Lua dispatcher reports through the native boundary

`lunette.reportError` lets a Lua dispatcher report a handler's error exactly as a raising callback is reported and continue. Reporting through `lovr.log` alone was rejected because no `onError` listener would hear it. Raising was rejected because it stops the later handlers, including the error display.

### Plugin failures are reported, not raised from the request

One drain loads and unloads many instances, so raising one instance's failure from another's request blames the wrong caller. Failures are reported and recorded as the instance's diagnostic. An operation a caller performs directly, such as `effect:dispose()`, raises its own failure instead. A definition without a name is named for its initializer's location.

### A published service is a view that its provider's activation revokes

Handing consumers the provider's own table was rejected: a reference kept past unload would reach torn-down state, every provider would need its own liveness guard, and consumers would share one mutable table. The view checks the provider's activation, not the consumer's, because a consumer's inverses call services while the consumer unloads, and dependents always unload before their providers. The view checks reads instead of wrapping methods, because a wrapper adds a stack frame that would misattribute errors raised at level 2.

### Subscriptions are context effects

`Context:on` tracks a native subscription with the activation, as Cordis's `ctx.on` does. It takes the subscribing function rather than an event name to keep the payload type. Wrapping each subscription in `Context:effect` by hand was rejected as repetition that invites leaks.

### The plugin runtime does not defend against a malicious plugin

Every plugin runs in the configuration's Lua state with the whole `lunette` API. The runtime's checks catch honest mistakes and stale handles; they are not a security boundary. Sandboxing would need a Lua state per plugin and a narrowed API, which is not planned ([Overview](overview.md#non-goals)).

### Contracts are declared only through capabilities

The facade does not export the native `contract` function, because an unbound token reserves a contract identity for the epoch without producing anything usable. `plugin.capability` declares and binds in one step.

### A child is enabled when it is installed

`Context:child` enables its instance, matching Cordis's `ctx.plugin`, because every caller would otherwise enable it at once. A conflicting reservation raises in the parent's initializer and fails the parent.

### Plugin calls take named fields

`plugin.define`, `plugin.capability`, and any plugin-system call whose positional arguments would not say what they are take a table of named fields, as in `tag:setSelected(owner, { selected = false })` and `rules:addSource(owner, { name, precedence, resolve })`. Named fields also let the facade reject a misspelt field. An owner-first call with one self-describing argument, such as `keyboard:new(owner, options)`, stays positional, as do the surface callbacks that follow LÖVR's ray and size conventions. The native API keeps its shapes except where the plugin system introduced a call.

The configuration type is inferred from the `init` annotation, so no configuration witness is needed. `Definition<C>` erases the context and publisher to `never`, because a recursive `Context` stops `Context:child` from checking its configuration. Explicit instantiation names a capability's service type, so no witness function is needed there either.

### Configuration types and validation share one descriptor

A descriptor states fields, defaults, children, choices, and constraints once, and supplies runtime validation, editor metadata, and the Luau input and output types. A runtime schema beside hand-written types was rejected because the two diverge. [Configuration schemas](../guide/configuration-schema.md#decisions) records the compiler constraints. Preflight rejects invalid settings before acquiring resources but cannot guarantee that an initializer succeeds.

### Composition has one start path

`plugin.compose` needs only the facade, so a configuration composes its own list without the desktop. Starting has one path, `management.start`, which preflights before activating anything. A second start path that validated at activation was rejected because the two would disagree on when a bad option fails.

### A typed patch is made from the definition

`plugin.configure(id, definition)` returns a function of the configuration. Inferring from the definition and the literal in one call widens literal options such as `hand = 'right'` to `string` and reports a correct call as an error. A table of typed functions per shipped entry was rejected because it restated the entry list and could not configure an inserted entry. The id is explicit because an entry's id need not be its definition's name.

### Frame dispatch and the surface list are contracts

Frame dispatch and the surface list are contracts with built-in providers, so any plugin requires them and either can be replaced alone. A configuration-local callback registry was rejected because a plugin could reach it only by copying the file. Phases name why a handler runs where it does, so a new handler need not read every other consumer's numbers to choose an order. The `binding` and `delivery` phases let a hotkey consume a key before it reaches the target, and input batches let physical sources record route eligibility before a binding changes it. Suppressing a single later text callback was rejected because LÖVR does not correlate text with keys.

`frame.install` binds the LÖVR callbacks outside any plugin, because the runtime is created from `lovr.load` and `lovr.quit` must close the runtime after the quit handlers. A provider assigning callbacks and restoring them on unload was rejected because restoration is correct only in strict reverse order.

### The checker reports a capability with an unknown service type

Omitting `<<Service>>` leaves the service type `unknown`, and nothing read through the capability is checked. `crates/lunette-lovr/src/analyze.cpp` walks each checked module and reports calls whose result is a capability at `unknown`. Making the omission a type error in the facade's signature was rejected: a type function on the return type pushed every `Context:require` past the checker's complexity limit, and one on the parameter crashed the vendored solver across modules.

### A keyboard is laid out from keys

Keys carry `x`, `height`, and spacers, as keyboard-layout-editor's format does, so split keyboards, tall keys, and arrow clusters can be written. A uniform grid was rejected because it expresses none of them. A row advances by its shortest key so half-height spacer rows make half-row gaps. An action is a union discriminated by `kind` rather than a string format, and `custom` lets a hook give a key a meaning the provider lacks.

### Keyboard variation is two around hooks

`onKey` and `drawKey` cover sounds, haptics, non-keycode keys, press animation, and key shapes, receiving the default as their last argument. Wrapping a built keyboard cannot change its drawing because the provider calls itself through closures. A whole-keyboard draw hook was not added because `style` covers the plate. A hook receives the provider's `Board`, because a provider's option may name its own types where a contract may not.

### The keyboard contract is what consumers call

The contract exposes the surface, visibility, activation, text, held modifiers, drawing, and destruction. Legend lookup, latch and lock sets, rows, and style stay with the provider. Each owner draws only what it made, because a service-wide draw would show keyboards the drawing owner does not offer. Route changes clear modifiers at once so a modifier chosen for one receiver cannot reach the next. `Keyboard` restates the surface fields rather than intersecting `Surface`, because an intersection holds two function types for `setPose` and makes calls ambiguous; `vocabulary.Movable` exists for the same reason.

### Haptics reach a pointer through its creator

`Pointer:vibrate` forwards to the function the pointer's creator supplied, because only the creator knows the device. A separate feedback contract keyed by pointer was rejected as one more agreement for one function.

### Layouts are a broker

Several layouts coexist under names and a consumer chooses one by a string, which a configuration or a tag can carry. A contract per layout, varied by replacing its provider, was rejected: it allows one layout at a time and shapes the contract like its first implementation. A layout takes a panel list so it needs no tags service, and `continuous` keeps the broker a registry.

### Drops are a broker of their own

Interaction emits drops; pose memory, persistence, and arrangement listen. Announcing drops through panels was rejected because interaction would require panels only to emit and only panels could be heard. Putting the event on the interaction contract was rejected because every listener would then go down with an interaction outage. Pose memory, which writes a dropped window's pose to its `lunette.pose` property, is a child of the `desktop/adoption` consumer rather than interaction's job, so a replacement interaction does not have to know about it.

### Focus is a contract of its own

Keyboard routing is separate from interaction, so a keyboard or a local receiver needs no pointer provider. One current route names the receiver of new input, while native seat authority stays per seat. Disposing a target never restores an older route, because the earlier owner may have ended. Forwarding to a native client after a local refusal was rejected because input would reach an application behind a local control.

### A pointer exposes what it hovers and carries

A pointer's grab offset, two-handed partner, pressed sink, and hand position stay private, because exposing them would oblige every replacement to reproduce them and let a driver corrupt them.

### Pointer buttons are a map

`Input.buttons` maps each held pointer button to true, so a right click or a remapped trigger needs no new provider. Which controller button holds which pointer button is device knowledge, so it is the laser's `buttons` option. A pinch strength was not added; a `readInput` hook can threshold one into a button.

### Interaction and laser variation is four around hooks

`drive` covers a different mapping because the primitives are public, and `constrain` covers a different grab feel because every carry passes through it. A `pick` hook was not added because `drive` can use the picking module. The laser's `draw` hook is called by the bulk draw, which a wrapper cannot reach.

### Bindings are a broker that takes its own presses

The bindings provider registers its own `binding`-phase handler, so a bindings outage leaves typing working. Having `desktop/input` dispatch to the broker was rejected because an outage would then stop all typing. Chords match exactly, so a binding for H does not fire for Control-H.

### Panel visibility is an owner-held override

Several plugins may want to hide a panel, and each one's say must end with it. The most recent live override decides, as with tag selection. Reverting to the value before an override was rejected because the result would depend on unload order. A hidden panel releases its layer at once so the compositor stops drawing it.

### A curve is LÖVR's layer curve

`curve` is the value `Layer:setCurve` takes, so a panel picks where the compositor draws it, and the scene mesh follows the same arc so losing a layer does not change the panel's shape.

### Decorations are a consumer

Panel chrome is off by default and `desktop/decorations` draws borders and titlebars from the panels contract's listeners, offering each bar as a surface that carries its panel. A decorator broker in the panels provider was rejected because the contract already gives a consumer what it needs.

### Tags are held, excluded, and announced

`hold` shares a tag among its holders, so entries need no start order. An exclusion is an owner-held override, so a plugin moves a window another plugin placed without taking that plugin's hold, and the window returns when the plugin unloads. Letting any owner remove any membership was rejected because the change would not end with its owner. Changes form one stream filtered by tag, and panel death is left to `panels:onRemoved`.

### A tag's layout is a name

A layout name can be saved and chosen from configuration, and keeps tags independent of layouts. A layout function on the tag was rejected for the opposite reasons.

### Placement is a contract of its own

Placement is the integration component of section 6.5 of the Cordis paper: it alone depends on rules, panels, and tags, and `panelOptions` is where a property reaches a panel. Mapping properties to panel options inside rules was rejected because rules would then require panels and tags. Placement announces every placement, so a plugin that places windows itself is arranged like an adopted one. Precedences are named so a user source can sit between the shipped ones.

### The error stream is a provider, and presenters are consumers

The provider keeps what presenters share, the subscription, the limiter, and the history, and any number of presenters subscribe. A contract that carried a quad's position was rejected because a notification presenter would have to fake it. Reports raised during delivery are kept and not delivered, so a raising presenter cannot feed itself.

### Pacing and scale hand out choosers

A rule with history or hysteresis needs state per window or output, and a pacer or chooser owned by its caller avoids telling the service when each one ends. A service that applied rates itself was rejected because reading the scene is a separate choice from the rule.

### A window names its output and its latest commit

Scaling by nearest panel needs a window's output, and pacing needs to know whether a client drew; both are mechanism, so they are handle fields. Comparing textures across frames was rejected because a texture lives for one frame and a client alternating two buffers repeats them. `commit` comes from a counter that never repeats, and is 0 rather than nil before the first buffer.

### Theme selection has a stable provider

The theme service is separate from the replaceable preset selector, so disabling the selector restores the base without removing a service the recovery UI requires. Last-live arbitration over whole themes avoids mixing palettes field by field. Sparse layers keep inheritance and explicit zeros. Faces are cached per specification and released by garbage collection, because recorded passes hold their own references and deterministic leasing cost more than the few faces a session loads.

### Themes are an open catalog

A theme comes from a plugin, and disabling the plugin removes it; the shipped themes use the same path. The catalog is separate from `lunette/theme` because a list of names has nothing to do with the font cache. A plugin calling `theme:select` with its theme was rejected because it would contend with the selector and never appear among its choices. Entries are complete themes so none silently inherits the base. The selector falls back to its configured theme while the chosen one is unregistered and returns to it when it registers again.

### UI geometry and activation tokens are public data

Declared geometry and detached descriptions give input, drawing, and automation one coordinate model. A frozen generation token distinguishes provider activations, because a numeric counter restarts after replacement and can repeat a panel's name and revision. A frozen owner token distinguishes creation-owner activations without exposing contexts. Control ids are namespaced by owner rather than by panel, because one owner may build controls across panels and several owners may contribute to one.

### Joined frames expose a narrow optional relationship

The attachment passes resolved header style to the target, which owns body drawing and knows whether it is eligible to join, so generic surfaces need not expose layer or curve state. A general container or transform API was rejected as unneeded. Dormant attachments persist so temporary layer grants or hiding cause no per-frame churn. [Rendering](rendering.md#joining-follows-the-actual-rendering-path) states the rendering side.

### Rounded controls retain rectangular targets

A conservative content clip keeps input and descriptions inside the rounded silhouette without changing declared bounds, and rectangular targets keep small controls usable at their corners. Analytic-circle picking was rejected because it accepts points outside the emitted mesh.

### Grapheme segmentation is native mechanism

Extended grapheme rules for combining marks, regional indicators, and emoji sequences are a correctness tail, so the native helper uses `unicode-segmentation` rather than a Lua implementation. Editing policy stays in Lua.

## Known gaps

Native events are named `lun*` inside LÖVR's event namespace. A collision with a future LÖVR event is unlikely but not excluded.

`lunctl` has root-equivalent access to the user's session; anything that can write to the socket controls the session. The socket is never network-reachable.

Source reload and hard restart run no cleanup for Lua modules outside the plugin runtime.

An error in a LÖVR callback that no Lua dispatcher protects ends the session with status 1. Recovering in the host would need each callback called under its own protected call, and a frame that unwinds between `lovr.headset.getPass` and `lovr.headset.submit` would still have to end the XR frame it began. A `lovr.errhand` that returns the previous loop skips the rest of the frame, including its submit.

A monitor panel cannot hold a composition layer, because `lunette.claimLayer` takes windows. The curved arc mesh and rounded scene geometry have not been seen on a GPU-backed session, and real font loading in installed and development sessions is unverified.

The focus source takes activations and committed UTF-8, with no held-key state, dead keys, compose, or IME preedit. Physical text invalidation is batch-wide. [Input](input.md#known-gaps) records the outstanding hardware acceptance.

Text shaping, bidirectional editing, and IME composition are absent from the UI toolkit, and draw hooks cannot make arbitrary pass misuse safe.

## Deliberately left open

Contract authorities are a naming convention and are not authenticated. Any module can declare a contract under any authority, including `lunette`, and the first declaration in an epoch holds the name and schema. Binding an authority to the package that may declare under it is left to plugin packaging and distribution, #39.
