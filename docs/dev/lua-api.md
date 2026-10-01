# The Lua API

## Two roots

```lua
local lunette = require '@lunette'  -- native mechanism.
local mullion = require '@mullion'  -- the Lua standard library, optional.
```

The roots have separate responsibilities. `lunette` exposes native mechanism for surfaces, textures, sinks, seats, outputs, processes, layers, clipboard, and capture. `mullion` contains optional Lua policy and presentation modules. The plugin facade, its neutral contracts, and the built-in plugin providers have separate roots under `@lunette-plugin`, `@lunette-contracts`, and `@lunette-plugins`.

The plugin facade does not replace either root. It provides lifecycle and service wiring for typed Lua components. The native `lunette` API remains usable without `mullion` or the plugin providers. `mullion` uses public APIs and contracts; it does not access private native state.

Module aliases and their runtime resolution are defined in [Module roots](build-and-development.md#module-roots) and `crates/lunette/src/aliases.rs`. `@lunette` is registered in `package.preload`. The plugin and standard-library roots are mounted from files. The runtime and static checker run in separate processes. Starting lunette does not run the static checker.

## The config

`~/.config/lunette/main.lua` is a LÖVR project. It defines `lovr.draw`, `lovr.update`, and the other LÖVR callbacks, and it `require`s lunette's libraries like any other module. Nothing is hidden, and no loop runs on the user's behalf without being defined in this file.

If this file does not exist, `$SYSCONFDIR/xdg/lunette/main.lua` is used directly. This matches awesome's approach, and avoids stale copies of a configuration the user never edited. `lunette --dump-config` produces a copy for the user to start editing.

A configuration that never mentions `mullion` is supported when it uses only the native API and plugin modules that do not depend on `mullion` helpers. The shipped configuration composes built-in providers with consumers under `etc/xdg/lunette/desktop/`; it uses `mullion.persist` for arrangement state and the shared `mullion.pose` and `mullion.keycodes` helpers through its policy and providers.

## Plugin authoring

`require '@lunette-plugin'` provides the typed authoring facade. A contract module defines a service type, declares the contract with `plugin.capability`, and exports the resulting capability. The service type is named by explicit type instantiation, and the fields name the contract and its schema:

```lua
local capability = plugin.capability<<Service>> { name = 'lunette/keyboard', schema = 1 }
```

The name is authority-qualified and the schema is a positive integer. Its service type describes the methods and fields that callers may use. The capability wrapper is frozen and binds to one native token when it is created, so the facade never hands out an unbound token. Declarations use that exact wrapper, and a Lua state cannot declare the same name and schema twice in one epoch. Contract vocabulary modules can hold shared types without creating a runtime dependency between service implementations.

A definition is a table of named fields. `name` labels the definition in logs, reports, and diagnostics. `requires` and `provides` declare capabilities by field name and default to empty. `init` is the initializer, which receives a `Context`, typed configuration, and init-only `Publisher`:

```lua
return plugin.define {
  name = 'layout/arc',
  requires = { tags = tags.capability },
  provides = { arc = layout.arc },
  init = function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    local service: tags.Service = context:require(tags.capability)
    publish:provide(layout.arc, create(context, service))
  end,
}
```

The facade rejects a spec with a field outside `name`, `requires`, `provides`, and `init`, a `name` that is not a non-empty string, an `init` that is not a function, and a `requires` or `provides` that is not a table. `plugin.capability` rejects a field outside `name` and `schema`, a `name` that is not a non-empty string, and a `schema` that is not a positive integer. Each error names the problem and points at the call. Definition names need not be unique.

`Context:require<T>(capability)` has the capability's service type. `Publisher:provide<T>(capability, value)` accepts the matching service type. The publisher is valid only while that initializer is active. `Definition<C>` carries configuration type `C`, which is inferred from the initializer's configuration parameter; service types belong to capabilities, not to a mapped services record. The facade does not validate or convert a configuration value at runtime. A capability's service type is fixed by the explicit instantiation; a call that omits it produces a `Capability<unknown>`, whose services the checker cannot type.

Luau checks local service shapes, methods, and configuration annotations in source modules. Runtime wiring remains a separate concern. The runtime matches authority-qualified contract name and exact schema. A required capability without a provider does not activate its consumer, and neither does a provider of another schema of the same name. The runtime rejects undeclared capability access, undeclared or duplicate provisions, missing or nil provided fields, extra fields, and calls to an expired publisher. A membership error names the contract and the plugin code that made the call. It does not inspect service table shapes or validate configuration values against Luau types.

The initializer stages all provided values. The native runtime publishes them as one provider generation only after the initializer succeeds and the graph confirms its bindings remain valid. If initialization fails or is cancelled, the provider publishes nothing and acquired effects are rolled back. An error an initializer raises keeps its own position and traceback. Plugin callbacks are synchronous and do not yield.

### Context operations

`Context:effect` registers a resource and its inverse with the activation. If the activation is cancelled while the acquisition runs, the call raises and the inverse is not left registered: it runs at once. Disposing an effect whose activation, instance, or runtime has ended does nothing.

`Context:on(subscribe, handler)` registers an event subscription as an effect. `subscribe` is a function that takes a handler and answers the function that cancels it, which is the shape of every `lunette.on*` event, so `context:on(lunette.onWindowOpened, handler)` subscribes for the life of the activation. The subscription is cancelled when the activation ends, and a handler that is reached after the activation has ended but before the cancellation runs, such as an error reported during cleanup, is not called.

`Context:child` installs a child instance owned by the current activation and enables it, so the child loads with its parent and is retired when the activation that installed it ends. `Context:active` checks whether the activation is live.

`Context:checkOwner` checks that a caller is a live context bound to the owning provider's current generation, and raises otherwise. `Context:owns` answers the same question with a boolean. `Context:acquire(owner, acquire)` checks the owner and registers the resource with the owner's lifetime, which is the common shape of an owner-scoped provider method. The adapter accepts only a context it wrapped as an owner; a table that copies a context's fields is rejected by `checkOwner` and `acquire` and is not owned.

### Services

A consumer receives each provision through a frozen view rather than the provider's own value. Every consumer of one provider generation receives the same view. Reading a field, calling a method, iterating, or calling a callable provision through the view raises an error naming the contract once the provider's activation has ended, including through a reference the consumer kept past its own activation. The view stays readable while the provider's activation is published and has not begun unloading, whatever the provider's resource authority: a provider whose explicit disposal failed acquires nothing more but keeps serving until it unloads. Assigning a field raises at any time. A method receives the view as `self`, so a provider reads its own fields through `self` and keeps mutable state in its own locals. The view checks a method when it is read rather than wrapping the call, so it adds no stack frame and a provider error raised at level 2 still names the consumer's call site. A function value read while the provider was live remains callable afterwards, as does any object a method returned; those objects carry their own `dead` state. `pairs` and `#` see an empty table; a service is read by field or iterated with generalized iteration.

### Confinement

A plugin changes state outside itself only through its context. Every resource, subscription, and child an initializer creates is registered through `Context:effect`, `Context:on`, `Context:child`, or an owner-scoped provider method, so unloading the instance reverts it. A direct `lunette.onWindowOpened` call in an initializer is not tracked: the subscription survives instance reload and disable, and a reloaded instance subscribes a second time. Source reload clears native subscriptions, which hides the leak only until the next instance reload.

Effects are flat. An effect created inside another effect's acquisition is registered with the context it was created through, as a sibling of the outer effect, and it is registered before the outer one because the outer inverse is registered only when its acquisition returns. Inverses run in reverse registration order when the activation ends, so the outer inverse runs before the inner one. An outer inverse that must release the inner resource first disposes the inner effect itself; disposing it again later does nothing.

An owner-scoped provider method registers the resource on the caller's owner, so the resource ends with the caller. When the provider needs a service of its own to do that work, it calls the service with its own context as the owner, inside the effect it registers on the caller's owner. It does not forward the caller's owner: that would require the caller to depend on the provider's dependencies. The adoption provider's `install` follows this pattern with its rules binding.

Two active instances cannot provide the same contract and schema. Several implementations of one contract are composed through a broker, as section 6.2 of the Cordis paper describes: one plugin provides the contract, implementations register with it through an owner-scoped method, and it chooses between them or multiplexes them. The rules provider's sources have this shape.

### Instances

Runtime instances expose `enable`, `disable`, `dispose`, and `reload`; runtime shutdown disposes every instance. A request takes effect immediately, in the order it is made, and raises at the call that made it when the graph rejects it: an unknown or removed instance, an enable of a retired or quarantined instance, or an enable whose provided contract another enabled instance already reserves. `instance:state()` reports `inactive`, `loading`, `active`, `unloading`, `failed`, `quarantined`, or `removed`. `instance:diagnostic()` describes why the instance last failed or is not loading, or returns nil. Logs, reports, and diagnostics name instances by their definition's `name`. The native `define` takes the name as an optional argument and otherwise names a definition for where its initializer is defined. An initializer or inverse that fails while lifecycle work drains is reported through [the error path](#errors) rather than raised from the request that started the drain. [Architecture](architecture.md#plugin-runtime) states the reservation, retry, and quarantine rules. The adapter contains all erased casts; plugin modules use no compatibility facade for the earlier mapped `Services<R>` and `Provisions<P>` design.

Contract tokens and frozen capability wrappers are shared by runtime graphs in one Lua state's epoch. A runtime graph owns its plugin instances, service values, and effects. Source reload retires the old epoch, so a new configuration may declare the same contract names and schema numbers again, and a declaration that still holds a capability from the retired epoch is rejected as retired. Instance reload replaces one plugin activation without replacing the runtime or epoch. See [Architecture](architecture.md#plugin-runtime) for lifecycle ownership and cleanup.

The native plugin handles in `lua/lunette/init.luau` are nominal. Each declares a phantom field that exists only in the declaration, so a table, or another plugin handle, does not satisfy a parameter that takes a contract token, definition, runtime, instance, context, or effect.

## Events

The native layer pushes events through LÖVR's own event queue, so lunette events interleave with `lovr.keypressed` and other LÖVR callbacks in a defined order. A listener subscribes through the module and is answered with the function that cancels it:

```lua
local cancel = lunette.onWindowOpened(function(event)
  print(event.window.title)
end)
```

Several listeners may wait on one event. They are called in the order they subscribed, each under a protected call, and a listener that raises does not stop the ones after it — a library and a configuration listening for the same event are peers, neither displacing the other.

`crates/lunette/src/events/mod.rs` declares each event once — its name, the fields its payload carries, and the expression that fills each one — and both the subscription and its payload type are generated from that declaration. The handler's parameter is typed without an annotation: `event` above is a `WindowOpenedEvent`, and `lunprocessexited` hands over a `ProcessExitedEvent` whose `outcome` is the union of the three names it can hold.

A source reload clears every native subscription before it re-runs the configuration, so a listener registered by the previous configuration is not called again. A plugin subscribes through `Context:on`, which ends the subscription with the activation; [Plugin authoring](#confinement) states why. A subscription made outside a plugin lasts until it is cancelled or the next source reload clears it.

`boot.lua`'s poll loop unpacks four arguments, so a payload of more than four values would not arrive. Every event carries a table instead, including the events with one field, so the shape does not differ between callbacks and a field added later is not a change to a signature.

`event.outcome` on `lunprocessexited` says which of `event.code`, `event.signal`, and `event.message` is present, and `ProcessExitedEvent` carries the three names it can take. A program that never started is reported this way and no other, so a mistyped `argv` reaches the configuration here.

An event is delivered against the snapshot of the frame it was drained in. `onWindowClosed` therefore hands over a handle that is already dead; it still reports the title, size, and identifier the window had.

An error raised by one of these handlers is reported and does not stop the frame's remaining events from being delivered.

A pointer picks from surfaces rather than from panels alone. A surface answers where a ray meets it and how far away that is; a panel is one, backed by a window or a monitor, and a virtual keyboard is another, drawing itself. `@lunette-contracts/surface` and the interaction contract state it. Nothing in `lunette` knows about it: picking, hovering, and grabbing are policy, and the native layer supplies only the sink a panel routes to.

Finer-grained notifications are implemented in Lua. The native layer pushes flat events; a provider builds the notifications its contract needs on top of them, such as the panels contract's `onAdded` and `onRemoved`, and registers each listener on its caller's owner. Nothing native knows about them, so they stay replaceable with the provider.

## Handles

Window, monitor, process, seat, output, and claim handles are persistent objects with stable identity, refreshed at frame start. See [Architecture](architecture.md#handles) for the model and for why dead handles go inert rather than raising.

Reads are snapshot fields. Mutations are requests:

```lua
print(win.title)             -- last frame's value.
print(win.appId)             -- the client's application identifier.
print(win.width, win.height) -- the surface's size in pixels.
print(win.opaque)            -- true when the buffer's fourth component is padding, not alpha.
print(win.contentType)       -- 'none', 'photo', 'video', or 'game': what the client says it draws.
win:resize(1920, 1080)       -- a configure request; the client may ignore it.
win:setFrameRate(10)         -- how often this client is let draw; nil for unthrottled.
win:close()                  -- a close request, not a kill; watch for lunette.onWindowClosed.
win:getTexture()             -- this frame's pixels; never cache it.
win:stabilize()              -- a persistent texture, at a copy per damaged frame.
win:setProperty('pose', p)   -- keeps a value for this window across a reload.
win:getProperty('pose')      -- what was kept, or nil.
win:properties()             -- every key this window is carrying, as a table.
```

`win:close()` sends the xdg-toplevel close request. The client decides what to do with it: an editor with unsaved work puts up a prompt, and a client is free to ignore it entirely. The window goes when the client unmaps it, which arrives as `lunette.onWindowClosed`.

`win:resize(width, height)` configures the toplevel. The client resizes at its own pace, and `win.width` and `win.height` change when it commits a buffer — which may be at a different size, because a client is free to honour its own minimum or to round to a character cell. Nothing waits for that. The dimensions are whole pixel counts of at least one, and a value that is not raises.

Both return `false` on a dead handle, without raising. Both are requests, so neither reports what the client did; that arrives as an event or as a changed snapshot field.

`win:setFrameRate(hz)` sets how often the compositor answers this window's frame callbacks, which is how often its client draws. `nil` returns it to unthrottled, which is where every window starts; throttling is asked for rather than imposed. The rate is a finite number of hertz above zero, and a value that is not raises.

The rate is a ceiling with a floor under it. A rate below approximately 1 Hz is paced at 1 Hz rather than honoured, because a client answered no frame callbacks stops pumping its event loop and stops answering input with it — the difference between a panel that is cheap and one that appears hung. [Rendering](rendering.md#frame-pacing) states the rest. Which window deserves which rate is policy and belongs in `mullion`; this is the mechanism it is built on.

`win:stabilize()` is described in [Rendering](rendering.md#windowstabilize).

`win.opaque` reports that the window's current buffer has no alpha channel, so its fourth component is padding a caller forces to one rather than sampling. It is a property of the buffer and changes when the client renegotiates its format, so it is read each frame alongside the texture. [Rendering](rendering.md#alpha) states what a consumer does with it, and why premultiplied blending is the other half of the same subject.

`win.contentType` is `wp_content_type_v1`, and is a hint rather than a fact. The protocol has no events and no way to ask, and adoption is thin and uneven: a client playing video commonly reports `'none'`, and one reporting `'video'` may be paused on a still frame. It is reported rather than acted on, and `mullion.pacing` combines it with an observed commit rate to decide what is exempt from throttling. A configuration that wants a different rule has both halves.

`win.width` and `win.height` are pixels, and report the size the client last committed rather than the size last requested of it. They are part of the native surface rather than something the standard library derives, because converting a ray hit on a panel into a pixel coordinate for `sink:pointer` needs them, and `mullion` reaches for nothing the public API does not expose.

## Per-window properties

A source reload retains the Lua state, but clears configuration modules and callbacks. Configuration locals are recreated when `main.lua` runs again. Globals and values retained by protected modules remain in the state. `win.userdata` holds a Lua value on the handle; the native property store remains outside Lua:

```lua
win:setProperty('pose', '0 1.6 -1.5')  -- a number, a string, a boolean, or nil to remove.
win:getProperty('pose')                -- what was kept, or nil.
win:properties()                       -- { pose = '0 1.6 -1.5' }, a fresh table each call.
```

The two are for different lifetimes and both are wanted. State a rule can derive comes back when the rules re-run, and `userdata` is the right place for it. A pose the user placed by hand, a size they dragged, or a tag they assigned by hand is derivable from nothing, and a reload that lost it would scramble a hand-arranged workspace.

A property is a number, a string, or a boolean. A table raises, with the key named: a table holds Lua values, which is the same problem one level down. A caller wanting structure encodes it into a string and knows that it did. A number that is not finite raises for the reason a layer priority that is not does — it is a defect in the caller's maths, and one that came back after a reload would be much harder to trace. `nil` removes the key.

`win:setProperty` returns `false` on a dead handle, like every other mutation; the entries of a window that has gone are dropped, so there would be nothing to store into. `win:getProperty` still answers on one, for the reason a dead handle still reports its title: `lunette.onWindowClosed` is dispatched against the frame the window has already left, and a handler tidying up after a panel is exactly who wants to read what that panel stored.

`win:properties()` exists so that what survived a reload can be discovered rather than guessed at. A configuration that stores under a key it computed — a tag name, a monitor identity — cannot enumerate its own keys once the state holding them has gone.

Entries live as long as the window and not as long as the Lua state. A reload leaves them untouched; a window closing drops them.

`win.id` is stable for the window's whole life, and a source reload does not change it. The compositor thread is not restarted by a source reload, so the identifiers it minted remain valid and a configuration can re-associate with a window by reading `win.id` again. A hard restart does not change this either. It destroys the graphics device and the XR session, but the compositor thread survives both, so the identifiers stay valid across it. See [LÖVR integration](lovr-integration.md#restart-semantics). A hard restart replaces the Lua state, so configuration values that must survive belong in the property store or in persistent data keyed by a durable identity such as `win.appId` or a monitor identity.

Writing properties to disk is outside the native store's contract. A configuration or Lua library decides which values to persist across a hard restart.

## Outputs

An output is a virtual monitor lunette shows to the clients assigned to it. It is not one of the user's own screens — those are monitors, below — and it is not a panel; it is what a client sees when it asks what display it is on.

```lua
local out = lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }
local steps = lunette.scaleSteps()   -- the scale ladder, ascending.

for _, output in ipairs(lunette.outputs()) do
    print(output.id)                     -- the compositor's identifier.
    print(output.dead)                   -- whether the compositor has this output right now.
    print(output.width, output.height)   -- the mode, in pixels.
    print(output.scale)                  -- the scale factor, fractional.
    print(output.refresh)                -- hertz, not the millihertz the protocol carries.
    output:setMode{ scale = 2 }          -- change the mode; unnamed fields are kept.
    output:destroy()                     -- withdraw the output.
end
```

`lunette.newOutput` returns a handle before the compositor has made the output, so `output.dead` is true in the frame that created it — the same rule `lunette.newSeat` and `lunette.spawn` follow. Until then the handle reports the mode it was asked for.

`width` and `height` are required and are whole pixel counts; a monitor with no size is not one a client can lay out against. `scale` defaults to 1 and `refresh` defaults to 60. A scale or a refresh rate that is not finite and positive raises, because a client told its monitor has a scale of zero divides by it.

`refresh` is in hertz here and in millihertz on the wire. Nothing above the native boundary deals in millihertz.

Refresh is advertisement, not pacing. It is what a client reads off `wl_output.mode` and reasons about; how often the compositor actually answers a surface's frame callbacks is `window:setFrameRate`, which is separate.

`output:setMode` keeps the fields it was not given, so `setMode{ scale = 2 }` changes the scale alone. Clients reallocate their buffers and re-lay-out in response, and some — GTK in particular — do it aggressively, so a configuration that adjusts this continuously will see them struggle. `mullion` moves between discrete steps with hysteresis for that reason.

`lunette.scaleSteps()` answers with the scale ladder, ascending, as plain numbers. It is the same ladder a claimed layer's requested size is quantised against ([Rendering](rendering.md#the-layer-pool)), and it is one ladder rather than two so that raising a panel's scale asks the pool for a rung the free list already holds instead of forcing an allocation. Each call returns its own table, so writing into what one call handed back does not change what the next reads. `mullion.scale` moves along it with hysteresis; a configuration that wants different steps is choosing among these, not adding to them.

`lunette.spawn{ output = out }` is how a client is assigned one, and it takes an output handle rather than an identifier so that a number in range cannot be mistaken for one. The assignment is made at spawn and lasts the client's life; there is no way to move a running client to another output, because the filter is only consulted when a client reads the registry or binds, so a change would have to withdraw the global and create a new one — which the client experiences as a monitor unplugged and replugged. Changing the mode of the output a client is already on is the supported operation.

A session starts with one output, and it is what a client that was assigned none is shown. Every client adopted from outside lunette is one of those, since nothing spawned it and so nothing named an output for it, and a client with no `wl_output` at all cannot pick a scale or a refresh rate. That one refuses to be destroyed, as the seat every session starts with does: `output:destroy()` on it returns `false`. Destroying any other output moves its clients to that starting output rather than leaving them on one that no longer exists: their assignment is cleared, their windows are reconfigured against the starting output's bounds, and the starting output's global is withdrawn and advertised again so a client that has already read the registry is offered it. Those clients see one monitor unplugged and another plugged in, which is the same cost `lunette.spawn{ output = out }` records for the reassignment it does not offer. Transform and physical size are not settable: the physical size is derived from the mode so that a client's density guess agrees with the scale lunette advertises.

## Monitors

`lunette.monitors()` returns the user's own screens, which lunette mirrors through the screencast portal rather than hosting. They are not compositor windows and they are not outputs; a window belongs to a client lunette runs, and a monitor belongs to the machine lunette runs on.

```lua
for _, monitor in ipairs(lunette.monitors()) do
    print(monitor.id)              -- the saved identity, stable across a restart.
    print(monitor.name)            -- as a user would recognise it: 'Acme X24 on DP-1'.
    print(monitor.width, monitor.height)               -- the resolution, in pixels.
    print(monitor.x, monitor.y)                        -- where it sits, in logical coordinates.
    print(monitor.logicalWidth, monitor.logicalHeight) -- how large it is there.
    print(monitor.mirrored)        -- whether a capture stream is running.
    print(monitor.pending)         -- whether one has been asked for and not arrived.
    monitor:getTexture()           -- this frame's pixels, or false.
    monitor:mirror()               -- start capturing; may prompt.
    monitor:setPaused(true)        -- stop the stream, keep the node.
    monitor:dismiss()              -- stop capturing; no ongoing cost.
end
```

The list is ordered by identity rather than by the order the host enumerated the screens, so an arrangement derived from it does not change when a cable is replugged and nothing else has.

`monitor.id` is the identity described in [Host desktop](host-desktop.md#identity-and-lifecycle): the make and model where the host reports one, a connector name where it does not, and the monitor's logical position where neither is available. It survives a restart and survives the monitor moving to a different port, so it is what a table of per-monitor state is keyed by.

`monitor.width` and `monitor.height` are pixels — the size a captured frame arrives at. `monitor.logicalWidth` and `monitor.logicalHeight` are the compositor's logical coordinates, which differ from pixels by the scale factor on a scaled display. Pointer positions are in the logical space; a texture is in the pixel one.

`monitor:mirror()` is a request. It returns immediately, and may put a portal dialog on the user's screen: nothing waits for one, because a frame cannot. `monitor.pending` is true while a request is outstanding, and `monitor.mirrored` becomes true some frames later — or never, if the user declines. A configuration that treats mirroring as synchronous draws an empty panel. It returns `false` only when the monitor is gone or the portal could not be asked at all.

Capture starts lazily. Nothing is requested of the portal until the first `monitor:mirror()`, so a configuration that mirrors nothing never prompts.

`monitor:dismiss()` stops the capture for real: the stream is torn down, so a dismissed monitor has no ongoing cost. The portal session is kept, so mirroring the monitor again does not prompt a second time. It returns `false` when nothing was running, which is not an error — dismissing twice is how a configuration says "make sure this is off".

`monitor:getTexture()` returns the texture holding the monitor's latest captured frame, and is valid for that frame only — PipeWire cycles a small pool of buffers and the texture rotates with them. Call it again each frame rather than caching it. It returns `false` in three ordinary cases: the monitor is gone, it is not mirrored, and it is mirrored but has produced no frame yet, which is what a still desktop looks like since an unchanging monitor sends nothing at all.

The texture matches the captured output's resolution, which is `monitor.width` by `monitor.height`.

`monitor:setPaused(paused)` is the middle case, for a panel that has left the user's view. The stream stops producing but is not given up, so resuming costs nothing. Reach for `dismiss` when the user closed the panel, and for `setPaused` when they merely turned away.

`lunette.onMonitorAdded` fires for each monitor at startup and for each one attached afterwards. It carries `event.id`, and `event.monitor` when the screen is still attached by the time the handler runs.

## Sinks and input domains

A sink is somewhere pixel-space input can be delivered. `window.sink` names one for a window lunette hosts, and `monitor.sink` names one for a mirrored screen, and the two behave differently in a way that is exposed rather than hidden:

```lua
print(sink.domain)             -- 'window' or 'host'.
print(sink.window)             -- the window a window sink reaches, or nil.
print(sink.monitor)            -- the monitor a host sink reaches, or nil.
print(sink.id)                 -- the compositor's identifier, or nil for a host sink.
sink:pointer(x, y)             -- pixel coordinates on the target.
sink:button('left', true)      -- press; false releases.
sink:leave()                   -- the pointer stops hovering; focus is untouched.
sink:scroll(dx, dy)            -- a continuous distance, in surface-local pixels.
sink:scrollDiscrete(dx, dy)    -- whole wheel notches.
sink:key(keycode, true)        -- an evdev keycode; false releases.
sink:modifiers{ 'shift' }      -- the modifiers held from now on.
sink:typeText('café')          -- text, whether or not the layout can express it.
```

A window sink's events go to that client through its seat, so each window has independent focus and its own cursor. A host sink's go to the user's desktop through lunette's input provider, and every host sink shares one cursor and one keyboard focus, because the host has one of each. Two hands pointing at two mirrored monitors cannot produce two cursors. [Host desktop](host-desktop.md#the-input-domain-leak) states why that is surfaced rather than papered over.

`sink:pointer` and `sink:button` take pixel coordinates on their target — the window's committed size, or the monitor's resolution. A coordinate that is not finite raises, because it is a defect in the caller's maths rather than a race. Every method returns `false` on a dead handle without raising: a client can exit, and a monitor can be unplugged, between the raycast and the click.

`monitor.sink` exists whether or not the monitor is mirrored. Pointing at the host desktop does not require lunette to be showing it.

`sink:leave()` is hover, not focus. It withdraws the pointer from whatever it was over without changing which sink holds the keyboard, so a panel library can highlight what one hand is pointing at without that hand taking the keyboard from the other. It returns `false` on a host sink: the host cursor is always somewhere on the host desktop, and there is no position that means "nowhere".

The two scroll methods are separate because the protocol keeps the two sources apart. A notched wheel sends whole steps and a trackpad sends a continuous distance, and a client uses the difference to decide whether to scroll kinetically. An axis whose delta is zero sends nothing. A host sink takes both axes and converts to wheel detents, at ten surface-local pixels per detent.

`sink:key(keycode, pressed)` takes an evdev keycode, which is what `wl_keyboard` carries and what `seat:strokeFor` hands back. On a window sink it goes to the seat's keyboard and so reaches whichever client that seat is focused on; a seat with no focus delivers to nobody. On a host sink it reaches whatever the host compositor currently focuses, and lunette does not choose what that is. A keycode outside the set lunette's host provider declared is refused with `false` rather than sent, because the kernel would otherwise drop it without a word.

`sink:modifiers(names)` replaces the modifiers held, rather than pressing modifier keys. `lunette.modifierNames()` answers with the names it takes, in the order a keymap numbers them, and an unrecognised one raises; `KeyModifier` in `crates/lunette-compositor/src/protocol/input.rs` is where the set is declared and everything else derives from it. A host sink refuses a set containing `mod3`, because neither the virtual-keyboard protocol nor uinput has a bit for it and applying the rest would leave the host holding something the caller did not ask for.

`sink:typeText(text)` is an escape hatch, and explicitly stateful. Text the active layout can type goes down the ordinary path and changes nothing; the rest makes lunette generate a temporary keymap, upload it, type against it, and put the client's own back. So it must not be interleaved with `sink:key` on the same seat, and a client may see its keymap change while it runs — which is legal, and is the price of entering text no layout binds. Text needing more distinct keysyms than one keymap holds is split into runs that fit rather than refused. It is refused on a host sink, because lunette does not own the host's keyboard well enough to promise the layout it took can be given back.

Every one of these methods takes an optional trailing seat. Leaving it off addresses the seat every session starts with, which is what a configuration that never calls `lunette.newSeat` wants. A host sink ignores the argument: the host has one cursor and one keyboard focus however many hands point at it.

## Seats

A `wl_seat` carries exactly one pointer and one keyboard, so two simultaneous cursors need two seats and the protocol offers nothing else. [Input](input.md#seats) states why.

```lua
local left = lunette.newSeat('left', { layout = 'de', repeatDelay = 200, repeatRate = 50 })

for _, seat in ipairs(lunette.seats()) do
    print(seat.id, seat.name)      -- the identifier, and what clients see on wl_seat.name.
    print(seat.dead)               -- whether the compositor has this seat right now.
    print(seat.modifiers)          -- an array of names; what clients were last told.
    print(seat.layouts)            -- an array of one: 'English (US)', not 'us'.
    print(seat.clipboardBridge)    -- whether this seat's selections are the host's.
    seat:setFocus(win.sink)        -- gives this seat's keyboard to a sink; nil withdraws it.
    seat:setModifiers{ 'shift' }   -- the same request sink:modifiers makes.
    seat:symbolFor(30)             -- the keysym a keycode produces, or nil.
    seat:characterFor(30, { 'shift' })  -- the text it types, or nil.
    seat:strokeFor('A')            -- { keycode = 30, modifiers = { 'shift' } }, or nil.
    seat:setClipboardBridge(true)  -- makes this seat's selections the host's.
    seat:destroy()                 -- withdraws the seat.
end
```

`lunette.newSeat(name, options)` returns a handle before the compositor has made the seat, so `seat.dead` is true in the frame that created it — the same rule `lunette.spawn` follows. The name is what clients tell two seats apart by, and it is the only thing on the wire that does, so a name another seat already has raises.

The options are the five names libxkbcommon compiles a layout from — `rules`, `model`, `layout`, `variant`, and `options` — plus `repeatDelay` in milliseconds and `repeatRate` in repeats per second. An absent layout name takes the desktop's own default, read from the `XKB_DEFAULT_*` variables, which is what a user who configured a layout for their session expects lunette to inherit. Key repeat defaults to a 200ms delay and 50Hz, and a rate of zero disables it; the timing is policy, so it lives here rather than in the native layer. A layout that does not compile is reported in the log and the seat never appears.

A seat carries exactly one layout, so `layout` naming several — `'us,de'` — is refused and the seat never appears. Every keymap query answers for the seat's one layout and nothing can read or set an active group, so a seat with two would answer for the first whichever one the user had switched to. A configuration wanting two layouts makes two seats. [Input](input.md#decisions) records the reasoning and what lifting it would take.

An inherited default naming several layouts is treated differently, because a desktop configured with `us,de` is ordinary and the user did not ask lunette for anything. The list is narrowed to its first entry, with the matching entry of the variant list, and the seat is created on that one layout. The narrowing is reported in the log, with the note that a second layout wants a second seat. So `layout = 'us,de'` leaves the seat uncreated, and `XKB_DEFAULT_LAYOUT=us,de` does not.

`seat:setFocus(sink)` is what gives a client the keyboard. Nothing infers focus from pointer motion — that heuristic is what makes a second hand steal focus by hovering — so a configuration that wants focus-follows-hover writes it. `nil` withdraws focus. A host sink returns `false`: which window on the host desktop holds the keyboard is the host compositor's decision.

`seat.layouts` is an array of one, for the reason above; it is an array because that is what `wl_keyboard`'s keymap carries and a second entry becomes possible if group switching ever lands. It, `seat:symbolFor`, `seat:characterFor`, and `seat:strokeFor` are the keymap queries [Input](input.md#keyboard) asks for. They are what lets a virtual keyboard draw correct legends and produce correct keycodes without reimplementing xkb in Lua. All of them answer from the seat's own layout, so two seats on different layouts answer differently.

`seat:strokeFor(value)` is the reverse lookup. A string is read as the character to type and a number as a keysym, and the answer prefers the fewest modifiers and then the lowest keycode, so a digit resolves to the number row rather than the keypad. It returns `nil` for anything the layout cannot express — that is what `sink:typeText` is for — and raises on a string of more than one character, because a stroke produces one keysym.

`seat.clipboardBridge` and `seat:setClipboardBridge(bridged)` are the host clipboard's one connection to a seat. The host desktop has one clipboard and one primary selection while every seat has its own, so exactly one seat is bridged: its selections are the host's in both directions, and every other seat's stay inside lunette. Bridging a seat takes the bridge off whichever seat had it, and passing `false` on a seat that is not the bridged one does nothing, so a configuration can call either without first asking which seat holds it. The seat every session starts with is bridged, so a configuration that never mentions the clipboard behaves as a single-seat compositor does. [Input](input.md#clipboard) states the mapping and [its decisions](input.md#decisions) state why it is one seat rather than all of them.

A selection the newly bridged seat already held is not pushed to the host retroactively; the next copy on that seat crosses. Both calls return `false` on a dead seat, like every other seat method.

`seat:destroy()` withdraws the seat. The seat every session starts with refuses: a session with no seat can deliver no input.

## Layer claims

A panel renders either as an in-scene quad or on an OpenXR composition layer. The second is sharper, because the runtime composites the source at its native resolution instead of resampling lunette's own resampling of it. Layers are scarce, so a panel asks for one:

```lua
local claim = lunette.claimLayer{
    window = win,               -- the source whose pixels the layer carries.
    width = win.width,          -- the requested size, in whole pixels.
    height = win.height,
    priority = 10,              -- where this ranks against every other claim.
}

print(claim.granted)         -- whether it holds a layer this frame.
print(claim.layer)           -- the LÖVR Layer, or false; never cache it.
print(claim.width, claim.height) -- the layer's size, not the requested size.
print(claim.window)          -- the source it was made for.
print(claim.priority)        -- the number last supplied.
claim:setPriority(20)        -- reranks it; takes effect at the next boundary.
claim:release()              -- withdraws it, returning the layer to the pool.
```

`claim.layer` is a real LÖVR `Layer`, not a wrapper, so `setPose`, `setDimensions`, `setCurve`, `setViewport`, `getTexture`, and the rest are the documented `Layer` methods. It is `false` whenever the claim holds none.

The priority is Lua's own number and lunette never invents it. Rust sorts by it, stably, and assigns the top N; focus, gaze, distance, a rule ranking video above a terminal, and hysteresis to stop grants flapping are all cases of computing a different number. A priority that is not orderable — nan — raises, because a claim silently keeping its old ranking would be diagnosed as the pool misbehaving.

`claim.width` and `claim.height` report the layer's size rather than the size that was asked for. Requested sizes are quantised to a ladder of discrete steps, described in [Rendering](rendering.md#the-layer-pool), so the layer is at least as large as the request and usually larger. A caller setting the layer's viewport wants the rung.

Grants and revocations land on frame boundaries and never mid-frame, so a panel's realisation cannot change between its `lovr.update` and its `lovr.draw`. A fresh claim therefore holds nothing in the call that made it, and may hold nothing indefinitely if higher-priority claims keep the pool full. Both paths are live from the start: the in-scene quad is the fallback, not a degraded mode.

Grants and revocations also arrive as callbacks, so a panel does not have to poll for them:

```lua
function lunette.onLayerGranted(event)  -- event.claim, event.layer.
function lunette.onLayerRevoked(event)  -- event.claim.
```

Both fire at the boundary the change lands on, before `lovr.update`, so a handler reading `event.claim.granted` agrees with the event it was handed. `lunlayerrevoked` carries no layer because there is none by then. An error raised in either handler is reported and changes nothing: both had already happened before the handler ran.

Revocation does not kill the claim. `claim.granted` goes false and `claim.layer` answers `false`, and the claim takes a layer again as soon as one frees and nothing outranks it — which is what makes the upgrade automatic. A claim is dead only after `claim:release()`, and a dead handle reads its last-known values and answers `false` from its methods.

Releasing is explicit. Nothing releases a claim when its handle is collected, because the grant and revoke events carry a second handle to the same claim and collecting that one would withdraw a live claim. A configuration that drops a panel releases the panel's claim.

## Scene rendering

Once every panel is on a composition layer there is nothing left for lunette to draw itself, and drawing an empty projection layer costs a swapchain acquire, a render pass, and a multisample resolve every frame for no picture.

```lua
lunette.setSceneEnabled(false)   -- skip lunette's own scene rendering.
print(lunette.sceneEnabled())    -- what was last asked for.
```

Skipping means `lovr.draw` is not called and the projection layer is left out of the frame. The XR frame is still submitted, and the composition layers still are, so panels on layers keep updating; what stops is lunette's own rendering. [Rendering](rendering.md#frame-pacing) records what an idle frame still costs.

A change takes effect at the next frame boundary rather than immediately, because the frame's layer list has already been submitted with the answer the frame started with. A configuration therefore sets this from `lovr.update` and reads the effect on the frame after.

Deciding is the configuration's, and lunette has no way to check. Everything drawn in `lovr.draw` is the configuration's own: a panel that holds no layer, a panel's chrome, a laser, an error panel, or anything else it draws. Turning the scene off while still drawing means the drawing does not happen, and the value defaults to on so that a configuration that never mentions it behaves as it always did. `mullion` does not set it, and the shipped configuration does not either: it draws chrome around every panel and a laser for every hand, so its scene is never empty.

## Reload

Source reload and hard restart preserve running applications. Plugin instance reload is a separate operation that replaces one activation within its runtime.

`lunette.reload()` performs a source reload in the current Lua state. It shuts down plugin runtimes, clears native event subscriptions, clears the callbacks owned by `main.lua`, drops unprotected entries from `package.loaded`, advances the plugin contract epoch, and runs `main.lua` and `lovr.load` again. It retains the LÖVR modules, XR session, GPU objects, compositor, and clients. Globals and the Lua state remain. A failed reload leaves the session running with whatever the failed configuration installed before it raised.

Plugin effects are the only cleanup a source reload runs, and the native plugin runtime runs them. A Lua module that creates resources outside a plugin must release them through another lifecycle path or tolerate their continued existence.

The order is: plugin runtime shutdown, subscription clearing, callback clearing, `package.loaded` clearing, contract epoch reset, `main.lua`, then `lovr.load`. `lovr.load` runs because `main.lua` conventionally defines callbacks and does its setup there, so a reload that ran only the file would install the new callbacks and never run the new setup. It receives the same `arg` it is given at startup.

What survives is stated as roots rather than as a list of what goes, so that a module added later is cleared without the mechanism being updated. `lovr.*` and the interpreter's own modules — `string`, `table`, `math`, `os`, `package`, `coroutine`, `io`, `debug`, `bit`, `jit`, `ffi` — are kept; everything else goes. `crates/lunette/src/reload.rs` is the source of truth for both that set and the callbacks cleared, which deliberately exclude the ones `boot.lua` defines defaults for: `boot.lua` runs once per Lua state, and a soft reload does not make a new one, so clearing `lovr.log` would remove a default nothing would put back.

The Lua state itself is not closed. Globals and protected modules survive. `main.lua` locals are recreated when its module is run again. Values in modules whose `package.loaded` entries are cleared are recreated only if the new configuration requires them. A hard restart replaces the state and its globals.

Clearing the callbacks matters for the case the file no longer mentions them. Re-running `main.lua` redefines the callbacks it still defines, but a callback the user *deleted* would otherwise stay bound to the old function and keep being called, so a reload would silently keep executing code that is no longer in the file.

`lunette.reload()` answers `true`, or `false` and a message. It does not raise, and it does not fall into safe mode: safe mode is for a `main.lua` that fails to load at startup, and a reload that fails leaves the session running so the user can fix the file and reload again. A reload that reached `main.lua` and failed there has already torn the previous configuration down, so the session continues with whatever the failed run installed before it raised.

A reload asked for from inside a reload is refused with that message rather than performed. A configuration that reloads as it loads would otherwise recurse until the stack ran out, and taking the process down takes every connected client with it. In practice this means `lovr.load` is not a place to call it from; a key binding or a `lunctl` chunk is.

`lunette.restart()` performs a hard restart, using LÖVR's `lovr.event.restart`. This closes the entire Lua state and rebuilds it, tearing down graphics and the XR session with it. See [LÖVR integration](lovr-integration.md#restart-semantics). The result is a clean slate, with a visible hitch and brief blackness in the headset. It is used when a soft reload is not sufficient.

The host shuts down plugin runtimes clears native subscribers, flushes the final frame, quiesces or stops native users of the state, and closes the external LÖVR state. The next state creates a new plugin attachment and contract epoch. Lua modules that allocate native objects outside the plugin runtime get no cleanup callback before the state closes. External close still has allocator-bookkeeping concerns that this ordering does not resolve.

The host handles plugin cleanup when the event loop takes the restart, not when the restart is requested. `lunette.restart()`, a bare `lovr.event.restart()`, and LÖVR's own `lovr.filechanged` therefore use the same native shutdown order.

The call pushes the event and returns; the restart is taken once the frame's callbacks have returned and the event loop reads it. Nothing is performed inline, so there is no counterpart to the reload's refusal: a restart asked for from `lovr.load`, from inside a reload, or twice in one frame is one restart at the end of that frame. `lunette.restart()` raises only if `lovr.event.restart` cannot be reached, which is a broken build rather than a mistake in the configuration.

Wayland clients survive source reload and hard restart because the compositor owns the socket outside the Lua state. Process exit terminates them with the process.

## Errors

Three kinds of callback run under a protected call: the `lunette.on*` event listeners, plugin initializers and inverses, and the handlers a Lua dispatcher protects and reports through `lunette.reportError`. An error raised in one of them is logged with its traceback and emitted to every `lunette.onError` listener, and execution continues: the frame's remaining events are delivered, the plugin drain goes on, and the dispatcher calls its next handler. The shipped configuration selects the built-in error-display provider, which rate-limits repeated reports and draws the latest report on a floating quad.

LÖVR's own callbacks, `lovr.update`, `lovr.draw`, `lovr.keypressed`, and the others `boot.lua`'s `lovr.run` calls, are not protected by the host. An error raised in one unwinds the frame loop to `boot.lua`'s error handler, which calls `lovr.errhand` when one is defined and uses what it returns as the next frame loop. Without one, `boot.lua` prints the error and returns a loop that ends the process with status 1, which disconnects every client. Neither the host nor the shipped configuration defines `lovr.errhand`. The shipped configuration keeps its frame callbacks inside its callback registry, which protects each handler, so only an error in the registry's own dispatch reaches `boot.lua`. A configuration that defines `lovr.update` or `lovr.draw` itself protects its own body or accepts that an error there ends the session. [Known gaps](#known-gaps) records this.

The native side of the callback boundary is `crates/lunette/src/callback_error.rs`. It splits the message from the traceback, logs it, and notifies every `lunette.onError` listener. It does not look up a Lua handler or rate-limit errors. Each listener handles the event independently, so a configuration can omit the error-display provider. A session without a listener still gets native logging, but repeated errors are not rate-limited.

`lunette.reportError(context, message, traceback)` reports an error through the same boundary: it is logged and every `lunette.onError` listener receives it, with `context` leading the message and the traceback optional. A listener that raises does not make it raise. A Lua dispatcher that calls several handlers from one callback protects each handler and reports a handler's error with it, so one handler's defect does not stop the handlers after it. The shipped configuration's callback registry does this for `lovr.update`, `lovr.draw`, `lovr.quit`, `lovr.keypressed`, `lovr.textinput`, and the surface list, so a raising draw handler does not hide the error display that draws after it. The panels provider reports a raising panel listener the same way.

A plugin failure that happens while lifecycle work drains takes the same path. Its context names the phase and the definition, for example `plugin load: <definition> (instance 3)`, and the traceback of a raising callback is kept apart from the message. A plugin instance that is waiting for a provider is logged at information level and is not reported.

The built-in error-display provider subscribes to `lunette.onError`, formats and rate-limits reports, and draws a floating quad through a configuration-owned desktop consumer. It does not use the panels provider because an error report has no textured source.

The native layer owns exactly one failure path: if `main.lua` fails to load, safe mode starts. This is a minimal built-in configuration with a laser, one panel, a way to spawn a terminal, and a reload key. Without this fallback, a configuration error would produce a black headset with no way to recover, requiring the user to remove the headset and edit Lua at a desk every time.

The trigger is a wrapper around `lovr.boot`, installed after `boot.lua`'s chunk has run and before its coroutine is first resumed. `lovr.boot` is the function whose failure means the configuration did not start: a source that will not mount, a missing `main.lua`, a `conf.lua` that raised, a syntax error, and an error at the top level of `main.lua` all raise inside it. So does a `lovr.load` that raises, because `lovr.boot` ends with `return lovr.run()` and `lovr.run` calls `lovr.load` before it returns the frame loop. That is intended: `lovr.load` is where a configuration builds the state its later callbacks assume, and a session whose `lovr.load` raised halfway is not one those callbacks can run in. Everything after `lovr.load` happens once the frame loop has been returned, and goes to the boundaries above instead. `lovr.errhand` would be the wrong hook, because it is reached by every error that escaped a callback boundary and because it belongs to the configuration. Safe mode replaces the callbacks a half-run `main.lua` installed, so a configuration that raised partway through does not keep running alongside it, and the load error is shown on the panel rather than only logged.

Safe mode is compiled into the binary rather than installed, and `crates/lunette/src/safe_mode.lua` is what it runs. It requires `lunette` and nothing else — never `mullion`, since a broken standard library is one of the reasons `main.lua` may have failed — so it resembles the shipped configuration without sharing code with it. [Decisions](#decisions) below records why the duplication is deliberate.

## lunctl

`lunctl` sends a Lua chunk to the running instance over a Unix socket at `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600 inside a directory lunette creates at 0700. The chunk is evaluated on the Lua thread between frames within a wall-clock budget, and the result is serialised back.

The directory is what makes the 0600 requirement enforceable, and reproducing the path without it would reintroduce a race. `UnixListener::bind` creates the inode with `0777 & ~umask` and offers no pre-creation hook; `fchmod` on the listener's descriptor does nothing on Linux, because for a socket the descriptor refers to the socket object rather than to the inode; binding and then widening the permissions leaves a window in which a connection can be accepted and stays valid afterwards; and `umask` is process-global and not thread-safe. A directory only the owner can traverse closes all of that, whatever the socket's own mode says. `$XDG_RUNTIME_DIR` is checked for the same property at startup rather than trusted, because the specification that mandates it is not an enforcement.

```console
$ lunctl 'return #lunette.windows()'
3
$ lunctl 'for _, w in ipairs(lunette.windows()) do print(w.appId, w.title) end'
$ lunctl "return require('@mullion/pose').encode(lovr.math.newMat4())"
```

A chunk resolves a module by its own name, so `lunette` is reachable without a `require` even though a configuration binds it to a local. The lookup is globals first and modules second, and a module name is tried as written and then under the `@` root the session registers it at, so `lunette` finds `@lunette`. Only a module already loaded or holding a registered loader resolves this way: an unknown name is `nil`, as Lua specifies, rather than a module that could not be found. A name a chunk assigns is written to the globals, so the next chunk sees it.

`mullion`'s submodules are not reachable through the root, here or anywhere. The root deliberately re-exports nothing, so `mullion.pose` is `nil` and the submodule is required by its own path.

This is the most significant inheritance from awesome, more significant than any layout algorithm. awesome's design allows the whole window manager to be inspected and mutated from a shell prompt while it runs, which is a substantial part of its usability. `lunctl` also serves as the end-to-end test harness: it spawns a client, evaluates assertions, and tears down.

The plugin authoring API provides typed service contracts and runtime lifecycle management. It does not replace `lunctl` or make the control socket a typed protocol.

`lunctl` has three modes, which is awesome-client's shape: a chunk as an argument, a chunk on standard input, and an interactive prompt when standard input is a terminal. It has no line editing of its own; `rlwrap lunctl` supplies it. `--socket PATH` names a socket other than the resolved one, which is what the end-to-end tests drive.

The exit status says what happened, so a script can branch on it: `0` the chunk ran, `1` it raised, `2` it did not compile, `3` it ran past its time budget and was abandoned, `4` it returned something the protocol cannot carry, or more of it than one message holds, `5` the session did not evaluate it, `6` the session could not be reached, and `64` `lunctl` was invoked wrongly, which includes a chunk larger than one message carries. An answer too large is reported as the answer it is, not as a session that could not be reached: the session closing the connection would reach the client as an end of file, and a chunk that succeeded would be reported as a session that is not running. A load error and a runtime error stay apart because a caller acts differently on each; awesome collapses both into one string.

A top-level string prints without quotes and a string inside a table prints with them. The top level is what a shell captures, so `$(lunctl 'return win.title')` is the title rather than the title in quotes. A handle prints as `<window 3>`: its kind and the identity the session keys it on, and nothing a client could dereference.

Three things learned from awesome's version (`inspiration/awesome/lib/awful/remote.lua`):

- awesome's remote control is exposed on the session D-Bus, reachable by every process in the session, including Flatpak applications granted `--socket=session-bus`. This makes it possible for a sandboxed application to ask the window manager to run arbitrary Lua. A 0600 socket in `$XDG_RUNTIME_DIR` provides the same capability with a smaller attack surface.
- awesome enables remote control unintentionally. The manpage implies it is opt-in, but `lib/awful/init.lua:28` requires `awful.remote` unconditionally, so every configuration that calls `require("awful")` has arbitrary code execution enabled. lunctl is enabled deliberately, documented as equivalent to root access on the user's session, with a switch to disable it.
- awesome's serialisation is limited to booleans, numbers, and strings; every other value is converted with `tostring`. This is adequate for a REPL but insufficient for tooling. lunctl serialises nested tables, and represents handles as opaque ids.

No network transport is provided. The type is a Unix listener and nothing accepts a host or a port, so there is no configuration that makes this listen on a network address.

`LUNETTE_CONTROL=off` is the switch that disables it. Unset and empty leave it on, because in-headset iteration is what it exists for; any other value that is not `on` turns it off and warns. Since unset already means on, the only reason to set the variable is to turn the endpoint off, so an unrecognised value is a misspelt `off` rather than a misspelt `on`, and answering one by opening an endpoint equivalent to root access on the user's session is the failure worth protecting against.

## Bindings

The API is bound with `mlua`, which creates the session's Luau state and owns it for the session's lifetime. LÖVR steps that same state through the raw C entry points, and `mlua` reads and writes it through the Luau feature. The boot sequence keeps ownership with mlua and never closes a state it created a second time.

This choice is motivated by failure mode, not throughput. A Lua mistake should raise a catchable error rather than crash the window manager, because the premise of this project is that users write Lua that reshapes the system. mlua's per-call cost is negligible relative to the cost of a compositor and a GPU frame.

Luau has no FFI. A script that wants a C ABI directly has the standard library and the `lunette` API, and nothing else; calling native code from a configuration is not part of the contract. The `lunette check` command is available to catch a configuration that reaches for it.

The API is available only in the main Lua state. `lovr.thread` and `lovr.task` states do not receive it.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

mlua, on Luau, not the raw C API or LuaJIT FFI. A Lua mistake must raise a catchable error, not crash the window manager. lunette runs Luau (via mlua and the LÖVR-linked fork) so that the standard library and configurations are statically checked, and because a typed dialect catches the two defect classes the interpreter alone does not (a local referenced before its declaration, and an accidental global). LuaJIT was a supported build mode until the standard library carried annotations LuaJIT cannot parse, at which point the mode was removed rather than kept as something that builds and cannot run.

Control socket over Lua eval, not a typed protocol. awesome's design has held for seventeen years. lunette changes the transport (a 0600 Unix socket, not the session D-Bus), makes it deliberate rather than incidental, and serialises properly. The plugin API is a separate in-process composition mechanism; it does not narrow the remote evaluation protocol.

The plugin types cover each service, configuration, and capability use locally. An earlier mapped `Services<R>` and `Provisions<P>` design required a recursive inferred type for the complete provider graph. Luau exceeded its 20,000 subtype-normalization budget even for an empty initializer. The implementation does not change Luau compiler flags or limits. The mapped API was rejected in favor of direct capability reads and init-only publication. Runtime declarations and lifecycle checks validate graph wiring; static analysis does not claim whole-graph guarantees.

`LUNETTE_CONTROL` fails closed: anything that is not `on` disables the socket. The first version failed open on an unrecognised value, on the reasoning that the failure worth protecting against is one that silently enables the endpoint — which is right, and was implemented backwards. Unset and empty already mean enabled, so nobody sets the variable to turn the endpoint on; the only reason to set it is to turn it off, and every unrecognised value is therefore a misspelt `off` — `false`, `0`, `no`, `disabled`. Answering one by opening a socket that evaluates arbitrary Lua, having warned on stderr that a user who set the variable in a systemd unit or a `.desktop` file will never read, is the failure the switch exists to prevent. The cost is a session whose `lunctl` stopped working because of a typo, which is visible the moment it is used and is fixed by writing `on`.

Per-window state lives in a native store as well as in `win.userdata`, and the two have different lifetimes. `userdata` is a Lua value on a Lua handle. Source reload retains the Lua state but clears configuration modules and callbacks, so configuration locals are recreated while globals and protected modules remain. The native property store survives source reload because it is outside the Lua state. It holds values a configuration cannot derive from its rules, such as a pose or size placed by hand. The store holds a number, a string, or a boolean and refuses a table; a caller that needs structure encodes it as a string. The alternative considered was preserving `userdata` by serialising it during reload. That would fail on functions, coroutines, and handles or silently drop them. Entries are keyed by `WindowId` and last as long as the window. Source reload and hard restart leave the compositor thread running, so the identifier remains valid across both. Persistence to disk is outside the native store's contract.

Safe mode is a Lua chunk compiled into the binary, not a file installed beside the default configuration. It exists for the moment `main.lua` fails to load, and a broken standard library, a missing install, or a `LUNETTE_STDLIB_PATH` pointing at nothing is one of the reasons it might have — so a fallback that read anything off disk would be unavailable in a fair share of the cases it exists for. It therefore requires `lunette` and nothing else, never `mullion`, and does its own ray-plane solve for one fixed axis-aligned panel rather than reaching for the panels provider. That duplicates a little of the shipped configuration, which is the price of always working, and both sites say so, so neither is later simplified by pointing at the other. `crates/lunette/src/safe_mode.lua` is the chunk and `safe_mode.rs` embeds it with `include_str!`, so it stays a Lua file that an editor highlights and a diff can be read against `etc/xdg/lunette/main.lua`. The alternative considered was installing it as a third file under `$SYSCONFDIR`, which reads better and fails in exactly the case the feature is for.

### The lunctl time budget is best-effort

Decided 2026-08-06, built in Phase 7 Task 6. Mechanism changed 2026-08-10 when lunette moved from LuaJIT to Luau: a LuaJIT count hook became a native `lua_callbacks(L)->interrupt` that raises via `lua_error` once the wall clock passes the budget.

A `lunctl` chunk runs under a native interrupt callback that raises once the wall clock passes its budget. The interrupt fires at safepoints (loop back edges, calls, returns, GC), which is the bound Luau offers; it is the first safepoint at or after the deadline, not one every N instructions as the LuaJIT hook was. The chunk is abandoned at that safepoint. Three things escape it, and none is fixable from inside Lua.

Compiled code still reaches an interrupt: the VM checks the callback at safepoints, so even a compiled function is interrupted at call or loop-back-edge boundaries. LÖVR builds Luau without native codegen, so the interpreter is the engine and safepoints fire at every back edge; the escape that LuaJIT's `jit.off` existed to close (a compiled trace never returning to the interpreter) does not arise.

A function the chunk merely calls is bounded by the next call or loop-back-edge interrupt safepoint, not by a hook count. This was the LuaJIT escape (a hot callee entered its trace and the hook did not fire); under Luau it is closed by the same safepoint the chunk itself runs under, unless the callee is a native call.

The bound stays advisory. An `error()` raised from the interrupt is catchable, so a `pcall` inside the user's own chunk swallows it; and a loop inside a C function, a blocking allocator, or a native call is uninterruptible by any VM callback — the loop does not reach a safepoint. This is the same best-effort posture the LuaJIT hook had, re-expressed for the interrupt mechanism.

A hard bound would need a watchdog outside Lua. Since the chunk holds the Lua thread, the only thing such a watchdog could do is abort the process — turning a bad `lunctl` command into a crash that takes every connected client with it. That is worse than the hang it prevents, so it is not built. `lunette-v1.AC8.2`'s first clause is stated as best-effort in the design plan for the same reason, and the tests assert the escape as the behaviour it is rather than as an aspiration.

### lunctl refuses what it cannot represent

Decided 2026-08-07, building Phase 7 Task 7.

A serialiser meets values with no wire form: functions, coroutines, userdata that is not a lunette handle, and table or function keys. It errors on each, naming the path to the offending value, rather than falling back to `tostring`. Dropping content silently is a correctness bug per `CONTRIBUTING.md`, and the `tostring` fallback is exactly what [lunctl](#lunctl) criticises awesome's remote control for.

Three further cases needed an answer, and each is a source of silent corruption if left implicit.

**A cycle is an error, not a back-reference.** A back-reference would be more faithful, and it would make the value tree a graph that every consumer — including `lunctl`'s own renderer — has to be total over. A `lunctl` chunk that wants to inspect a cyclic structure can break the cycle itself; a renderer that has to guard against one cannot.

**Shared subtables are duplicated, and identity is not preserved.** That follows from the choice above: without back-references there is nothing to share with. The node cap is what keeps a wide directed acyclic graph from expanding without bound, and it produces a clean error rather than an allocation failure.

**Metamethods are not honoured.** Traversal is raw, so what is serialised is what the table actually holds. `__index` can fabricate fields that do not exist and `__pairs` can hide ones that do, and a wire format whose contents depend on which of those a caller happened to install is not an inspection tool.

**An answer too large to send is an answer, not a closed connection.** The frame cap is checked before anything is written, so a reply that does not fit leaves the session with nothing on the socket and something to say. Closing instead reaches the client as an end of file, which it can only report as a session it could not reach — a lie about a session that is running and a chunk that succeeded. So `Reply::Oversized` carries the size back, and `Reply::Malformed` does the same for a request the session could not read. Both are new tags, which is why the protocol version is 2. The node cap does not make this unreachable: it bounds how many values a reply holds and not how many bytes, so an ordinary chunk returning one long string reaches it without being pathological.

A handle serialises as its kind and the identity the session keys it on, never as `tostring(handle)`. Addresses are reused after collection, so an id derived from one could come to refer to a different object — a defect that appears only under memory pressure. The identity is `win.id` and its siblings, which Phase 6 recorded as the stable thing; the userdata itself is minted fresh on every read and is not identity-stable at all.

### The declarations are generated from the registration

`lua/lunette/init.luau` is what the type checker reads `require '@lunette'` as, because Luau resolves a require to a file on disk and a definitions file can only declare globals. It is generated rather than written: each property and method is declared once, beside the closure that answers it, and the same declaration registers it with mlua and states its type, its parameter names, and its prose.

The Luau type comes from the Rust one. `LuauType` maps a Rust type to its spelling — `f64` to `number`, `Option<T>` to `T?`, a handle to its own name — so a signature is derived rather than restated, and the spelling of a type exists in one impl rather than in every signature that uses it. Where Rust says less than Luau does, a wrapper type carries the difference: a texture that may be `false`, a string that is one of four words, an option table that validates its own keys as it is read. An option table's accepted names are the declaration's field names, so a table the runtime refuses cannot be one the type offers.

The alternative was a hand-written stub kept in step by hand, which is what this replaced. It drifted: one reading of it against the Rust found `sink:scrollDiscrete`, `window.contentType`, `lunette.setSceneEnabled`, `lunette.sceneEnabled`, and `lunette.restart` declared nowhere, each of which made a documented call fail the check. A second list is a second thing to forget, and nothing was checking.

### An event is subscribed to, not assigned

`lunette.onWindowOpened(handler)` answers the function that cancels the subscription, and several listeners may wait on one event. The events were `lovr.lunwindowopened` and its siblings before this: a function a configuration assigned, which is how LÖVR's own callbacks work.

The convention was reversed because assignment gives each event exactly one handler for the whole session, and lunette has two parties who want to hear: the configuration, and whatever library it loaded. Both workarounds that produced were in `mullion` before the change. `mullion.panel` polled `claim.granted` every frame rather than handle the grant, because taking the callback would have taken it from the configuration. `mullion.error` did take `lovr.lunerror`, and then called by hand whatever handler it had displaced. LÖVR shows the same cost in its own house: `lovr.errhand` is a slot, so `mullion.error` saved the previous handler and called it, which is the dance a slot forces on anyone polite enough to do it.

The typing followed from the same place. A Luau definitions file declares globals and cannot name a module's exported types, so a callback on `lovr` could not say it takes a payload carrying a `Window`, and every payload was declared `any`. A module function can, so a handler's parameter is typed with no annotation.

What it costs is a second convention in a file that already has LÖVR's: `function lovr.draw(pass)` sits a few lines from `lunette.onWindowOpened(function(event)`, and this document asks elsewhere for one convention rather than two. The two are different things — a frame hook has one owner and a notification has any number — and giving them the same shape is what produced the workarounds above. That is the trade, made knowingly.

`lunette.onWindowOpened = handler` was the alternative: assignment on the module table, which keeps LÖVR's feel and would have been typed, since the module can name its own types. It keeps the single slot, which is the defect, so it answers the smaller half of the problem and not the larger.

Only the way a listener is reached changed. The events still travel LÖVR's queue and are still drained through `lovr.handlers`, so they interleave with `lovr.keypressed` as they did, and the layering above stands: the native layer pushes flat events, and anything finer, such as the panels contract's `onAdded` and `onRemoved`, belongs to a Lua provider.

### Errors and safe mode

The native side of the callback boundary rate-limits nothing. `crates/lunette/src/callback_error.rs` logs the message and traceback and notifies every `lunette.onError` listener. The shipped configuration enables the built-in error-display provider, which owns its limiter, report formatting, and floating quad. A configuration can omit that provider. Without any listener, an error is still logged, but repeated errors are not rate-limited. [Errors](#errors) states this behavior.

The built-in error-display provider draws a quad rather than a panels-provider panel, because an error report has no textured source. Drawing needs a `Pass`, while reporting does not, so the provider reports through its service and a desktop consumer draws it. The provider subscribes independently to `lunette.onError`, so a configuration can replace its display without displacing a native handler.

Safe mode is triggered by wrapping `lovr.boot`, not by installing a `lovr.errhand`. `lovr.boot` is the function whose failure means the configuration did not load. `lovr.errhand` handles errors that escape callback boundaries and remains part of LÖVR's callback handling. Replacing it with the error-display provider would use the wrong boundary and couple the configuration's error policy to LÖVR's loop recovery.

The wrapper includes `lovr.load` failures because `lovr.boot` ends with `return lovr.run()`, and `lovr.run` calls `lovr.load` before it returns the frame loop. Safe mode replaces a configuration whose setup failed before its callbacks can run. Errors from `lovr.update`, `lovr.draw`, and event listeners occur after the frame loop has been returned and are not a load failure. [Errors](#errors) states which of them the host protects.

### A Lua dispatcher reports through the native boundary

`lunette.reportError` exists so that a dispatcher written in Lua reports a handler's error exactly as a raising callback is reported. Before it, the shipped callback registry ran every handler of a callback inside one call, and a handler that raised stopped the handlers after it every frame, including the error display that would have shown the failure. Reporting from Lua through `lovr.log` alone was rejected because it reaches no `lunette.onError` listener, so the error display and any other listener would not hear it. Raising and relying on the host's boundary was rejected because it is the behaviour being fixed.

### Plugin failures are reported, not raised from the request

An initializer or inverse that fails during a drain is reported through `lunette.onError` and recorded as the instance's diagnostic. It is not raised from `enable` or whichever request started the drain, because one drain loads and unloads many instances, and raising one instance's failure from another instance's request attributes it to the wrong caller. `instance:state()` and `instance:diagnostic()` let a caller that wants the outcome of its own request read it. An operation that a caller performs directly, such as `effect:dispose()`, raises its own failure, and that failure is not also reported, so it is not seen twice.

A definition defaults to the location of its initializer as its name. Requiring an explicit name would change every existing definition for a label that the source location already provides, and an anonymous definition would make an instance number the only thing a report could name.

### A published service is a view that its provider's activation revokes

A provision reaches consumers as a frozen view that raises once the provider's activation has ended and raises on every write. Before this, a consumer received the provider's own table. A reference kept past a provider's unload reached torn-down state, so every provider repeated a hand-written liveness guard, and consumers shared one mutable table that any of them could change for all the others.

The view is checked against the provider's activation, not the consumer's. A consumer's inverses run while the consumer unloads and its own activation has already ended, and they routinely call the services they depend on to release what they acquired; a consumer-side check would refuse exactly those calls. Dependents always unload before their providers, so the provider is still active while every dependent's inverses run. A consumer that leaks a service reference past its own activation is a confinement fault, and it is caught as soon as the provider it reaches has gone.

The view checks a read rather than wrapping each method. Luau has no tail calls, so a wrapper adds a stack frame, and every provider error raised at level 2 to name the consumer's call site would name the adapter instead. The cost is that a function read while the provider was live remains callable. A method wrapper cache was considered and rejected for the same reason. One view per provision, shared by all consumers of a generation, keeps the cost to one native liveness query per read.

### Subscriptions are context effects

`Context:on(subscribe, handler)` makes a native subscription an effect of the activation, which is how Cordis's `ctx.on` tracks a listener on its fiber. It takes the subscribing function rather than an event name, because `lunette` events are subscribed through typed functions such as `lunette.onWindowOpened`, and taking the function keeps the handler's payload type. Wrapping the subscription in `Context:effect` by hand was the alternative; every provider and desktop consumer did so, each with its own `context:active()` check in the handler, and an initializer that called `lunette.on*` directly leaked the subscription across instance reload.

### Contracts are declared only through capabilities

The facade does not export the native `contract` function. A token declared that way is unbound, so declaring `lunette/panels` at schema 1 through it reserved the identity without producing a capability anything could use, and blocked the real contract for the rest of the epoch. `plugin.capability` declares and binds in one step. The native function remains for the adapter and for tests of the native layer.

### A child is enabled when it is installed

`Context:child` enables the instance it installs, matching the `ctx:use` semantics of issue #32 and Cordis's `ctx.plugin`, where installing a child under a parent loads it. A disabled child would load only after a separate `enable`, and every caller made that call at once. Enabling inside the parent's initializer is a request like any other: a conflicting reservation raises in the initializer and fails the parent's load, which retires the child with it.

### Definitions and capabilities take named fields

`plugin.define` and `plugin.capability` each take one table of named fields. `plugin.define` took four positional arguments, a configuration witness, the required and provided declarations, and the initializer, and a call site did not say which empty table was which. Named fields also give a definition a declared name in place of the source position of its initializer, and they let the facade reject a misspelt field.

The configuration witness was removed because the initializer's configuration annotation carries the type. Luau infers `C` from the `init` field of a generic table parameter. `Definition<C>` keeps the initializer under `init` with its context and publisher erased to `never`. An initializer typed with `Context` there made `Definition` and `Context` mutually recursive, and `Context:child` then stopped rejecting a wrongly-typed configuration; the erased form keeps `C` in the type without the cycle.

The capability witness was removed from the call site because Luau's explicit type instantiation, `plugin.capability<<Service>> { ... }`, names the service type directly. The vendored Luau parses, checks, and compiles it, and StyLua formats it. `Capability<T>` still carries `T` through an identity witness, which the adapter now creates. The witness function at the call site was rejected because it repeated the service type twice in an identity function the runtime never needed.

## Known gaps

Named, not solved.

The `lovr.lun*` prefix squats in LÖVR's callback namespace permanently. It is distinctive enough that a collision is unlikely, but this remains an assumption rather than a guarantee.

`lunctl` has root-equivalent access to the session. Anything that can write to the socket controls the machine. This follows from the single-user assumption, stated explicitly, and the socket is never network-reachable.

Source reload and hard restart run no cleanup for Lua modules outside the plugin runtime. A module that retains native resources outside plugin instances can therefore outlive its configuration callbacks.

An error raised in a LÖVR callback that no Lua dispatcher protects ends the session. `boot.lua` calls `lovr.update`, `lovr.draw`, and the other LÖVR callbacks directly, and with no `lovr.errhand` its error handler replaces the frame loop with one that exits with status 1, which takes every connected client with it. The shipped configuration avoids it by dispatching through its callback registry, and a raw callback in a user's configuration does not. Recovering in the host would need each LÖVR callback called under its own protected call, through a host-owned `lovr.run` or a wrapper on every callback a configuration assigns, and a frame that unwinds between `lovr.headset.getPass` and `lovr.headset.submit` would still have to end the XR frame it began. Defining a `lovr.errhand` that returns the previous frame loop resumes the session but skips the rest of the frame, including its submit, so it does not settle that question either.

## Deliberately left open

Contract authorities are a naming convention and are not authenticated. Any module can declare a contract under any authority, including `lunette`, and the first declaration in an epoch holds the name and schema. Binding an authority to the package root that may declare under it is left to plugin packaging and distribution, #39.
