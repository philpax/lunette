# The Lua API

## Two roots

```lua
local lunette = require 'lunette'   -- native mechanism.
local mullion = require 'mullion'   -- the Lua standard library, optional.
```

The two names carry different contracts. `lunette` covers surfaces, textures, sinks, seats, outputs, processes, layers, clipboard, and capture. It is implemented in Rust and represents the full capability of the system. `mullion` covers panels, layouts, rules, signals, keybindings, and chrome. It is implemented in Lua, installed as readable files, and can be replaced.

awesome makes the same split by name, distinguishing `awesome`, `client`, and `screen` from `awful`. This is why writing a replacement for `awful` is a recognised option in that project. Nesting the standard library under `lunette.*` would present a single API in which part happens to be implemented in Lua, obscuring the distinction.

The two roots are usable independently. `mullion` is written against the same public `lunette` API available to any other caller. If `mullion` ever requires something private, this indicates a defect in the `lunette` API.

## The config

`~/.config/lunette/main.lua` is a LÖVR project. It defines `lovr.draw`, `lovr.update`, and the other LÖVR callbacks, and it `require`s lunette's libraries like any other module. Nothing is hidden, and no loop runs on the user's behalf without being defined in this file.

If this file does not exist, `$SYSCONFDIR/xdg/lunette/main.lua` is used directly. This matches awesome's approach, and avoids stale copies of a configuration the user never edited. `lunette --dump-config` produces a copy for the user to start editing.

A config that never mentions `mullion` is a supported configuration.

## Events

The native layer pushes events through LÖVR's own event queue, so lunette events interleave with `lovr.keypressed` and other LÖVR callbacks in a defined order. Callbacks are prefixed `lun`, and every one of them takes a single table:

```lua
function lovr.lunwindowopened(event) end   -- window.
function lovr.lunwindowclosed(event) end   -- window.
function lovr.luntitlechanged(event) end   -- window, title.
function lovr.lunmonitoradded(event) end   -- id, monitor.
function lovr.lunprocessexited(event) end  -- process, outcome, and one of code, signal, message.
function lovr.lunprocessoutput(event) end  -- process, stream, text.
function lovr.lunlayergranted(event) end   -- claim, layer.
function lovr.lunlayerrevoked(event) end   -- claim.
function lovr.lunerror(event) end          -- message, traceback.
```

The prefix occupies LÖVR's callback namespace permanently and is chosen to be distinctive: `lovr.lun*` is unlikely to collide with any callback added upstream.

`boot.lua`'s poll loop unpacks four arguments, so a payload of more than four values would not arrive. Every event carries a table instead, including the events with one field, so the shape does not differ between callbacks and a field added later is not a change to a signature.

`event.outcome` on `lunprocessexited` is `'exited'`, `'signalled'`, or `'spawnFailed'`, and says which of `event.code`, `event.signal`, and `event.message` is present. A program that never started is reported this way and no other, so a mistyped `argv` reaches the configuration here.

An event is delivered against the snapshot of the frame it was drained in. `lovr.lunwindowclosed` therefore hands over a handle that is already dead; it still reports the title, size, and identifier the window had.

An error raised by one of these handlers is reported and does not stop the frame's remaining events from being delivered.

Signals are implemented in Lua. The native layer pushes flat events; `mullion` builds `connect_signal`, `emit_signal`, property-change signals, and per-window signal tables on top of them. awesome's signal system is approximately 100 lines of Lua, an amount of machinery small enough to leave replaceable.

## Handles

Window, monitor, process, seat, output, and claim handles are persistent objects with stable identity, refreshed at frame start. See [Architecture](architecture.md#handles) for the model and for why dead handles go inert rather than raising.

Reads are snapshot fields. Mutations are requests:

```lua
print(win.title)             -- last frame's value.
print(win.appId)             -- the client's application identifier.
print(win.width, win.height) -- the surface's size in pixels.
print(win.opaque)            -- true when the buffer's fourth component is padding, not alpha.
win:resize(1920, 1080)       -- a configure request; the client may ignore it.
win:close()                  -- a close request, not a kill; watch for lovr.lunwindowclosed.
win:getTexture()             -- this frame's pixels; never cache it.
win:stabilize()              -- a persistent texture, at a copy per damaged frame.
win:setProperty('pose', p)   -- keeps a value for this window across a reload.
win:getProperty('pose')      -- what was kept, or nil.
win:properties()             -- every key this window is carrying, as a table.
```

`win:close()` sends the xdg-toplevel close request. The client decides what to do with it: an editor with unsaved work puts up a prompt, and a client is free to ignore it entirely. The window goes when the client unmaps it, which arrives as `lovr.lunwindowclosed`.

`win:resize(width, height)` configures the toplevel. The client resizes at its own pace, and `win.width` and `win.height` change when it commits a buffer — which may be at a different size, because a client is free to honour its own minimum or to round to a character cell. Nothing waits for that. The dimensions are whole pixel counts of at least one, and a value that is not raises.

Both return `false` on a dead handle, without raising. Both are requests, so neither reports what the client did; that arrives as an event or as a changed snapshot field.

`win:stabilize()` is described in [Rendering](rendering.md#windowstabilize).

`win.opaque` reports that the window's current buffer has no alpha channel, so its fourth component is padding a caller forces to one rather than sampling. It is a property of the buffer and changes when the client renegotiates its format, so it is read each frame alongside the texture. [Rendering](rendering.md#alpha) states what a consumer does with it, and why premultiplied blending is the other half of the same subject.

`win.width` and `win.height` are pixels, and report the size the client last committed rather than the size last requested of it. They are part of the native surface rather than something the standard library derives, because converting a ray hit on a panel into a pixel coordinate for `sink:pointer` needs them, and `mullion` reaches for nothing the public API does not expose.

## Per-window properties

A soft reload discards the Lua state, so anything a configuration must remember across one cannot be kept in Lua. `win.userdata` holds a Lua value and goes with the state; the property store is native and does not:

```lua
win:setProperty('pose', '0 1.6 -1.5')  -- a number, a string, a boolean, or nil to remove.
win:getProperty('pose')                -- what was kept, or nil.
win:properties()                       -- { pose = '0 1.6 -1.5' }, a fresh table each call.
```

The two are for different lifetimes and both are wanted. State a rule can derive comes back when the rules re-run, and `userdata` is the right place for it. A pose the user placed by hand, a size they dragged, or a tag they assigned by hand is derivable from nothing, and a reload that lost it would scramble a hand-arranged workspace.

A property is a number, a string, or a boolean. A table raises, with the key named: a table holds Lua values, which is the same problem one level down. A caller wanting structure encodes it into a string and knows that it did. A number that is not finite raises for the reason a layer priority that is not does — it is a defect in the caller's maths, and one that came back after a reload would be much harder to trace. `nil` removes the key.

`win:setProperty` returns `false` on a dead handle, like every other mutation; the entries of a window that has gone are dropped, so there would be nothing to store into. `win:getProperty` still answers on one, for the reason a dead handle still reports its title: `lovr.lunwindowclosed` is dispatched against the frame the window has already left, and a handler tidying up after a panel is exactly who wants to read what that panel stored.

`win:properties()` exists so that what survived a reload can be discovered rather than guessed at. A configuration that stores under a key it computed — a tag name, a monitor identity — cannot enumerate its own keys once the state holding them has gone.

Entries live as long as the window and not as long as the Lua state. A reload leaves them untouched; a window closing drops them.

`win.id` is stable for the window's whole life, and a soft reload does not change it. The compositor thread is not restarted by one — that is what a soft reload is — so the identifiers it minted are the identifiers it keeps, and re-associating with a window after a reload is a matter of reading `win.id` again. A hard restart is a different matter: it stops the compositor, and identifiers from before it name nothing. Anything that has to survive that is keyed on something the compositor did not mint, such as `win.appId` or a monitor's identity.

Writing any of this to disk is the standard library's own business. The store is live state; what of it is worth keeping across a restart is a decision `mullion` makes.

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

`lovr.lunmonitoradded` fires for each monitor at startup and for each one attached afterwards. It carries `event.id`, and `event.monitor` when the screen is still attached by the time the handler runs.

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

`sink:modifiers(names)` replaces the modifiers held, rather than pressing modifier keys. The names are `shift`, `capsLock`, `control`, `alt`, `numLock`, `mod3`, `logo`, and `mod5`; an unrecognised one raises. A host sink refuses a set containing `mod3`, because neither the virtual-keyboard protocol nor uinput has a bit for it and applying the rest would leave the host holding something the caller did not ask for.

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

A seat carries exactly one layout, so `layout` naming several — `'us,de'` — is refused and the seat never appears. Every keymap query answers for the seat's one layout and nothing can read or set an active group, so a seat with two would answer for the first whichever one the user had switched to. A configuration wanting two layouts makes two seats. [Decisions](decisions.md#recorded-decisions) records the reasoning and what lifting it would take.

An inherited default naming several layouts is treated differently, because a desktop configured with `us,de` is ordinary and the user did not ask lunette for anything. The list is narrowed to its first entry, with the matching entry of the variant list, and the seat is created on that one layout. The narrowing is reported in the log, with the note that a second layout wants a second seat. So `layout = 'us,de'` leaves the seat uncreated, and `XKB_DEFAULT_LAYOUT=us,de` does not.

`seat:setFocus(sink)` is what gives a client the keyboard. Nothing infers focus from pointer motion — that heuristic is what makes a second hand steal focus by hovering — so a configuration that wants focus-follows-hover writes it. `nil` withdraws focus. A host sink returns `false`: which window on the host desktop holds the keyboard is the host compositor's decision.

`seat.layouts` is an array of one, for the reason above; it is an array because that is what `wl_keyboard`'s keymap carries and a second entry becomes possible if group switching ever lands. It, `seat:symbolFor`, `seat:characterFor`, and `seat:strokeFor` are the keymap queries [Input](input.md#keyboard) asks for. They are what lets a virtual keyboard draw correct legends and produce correct keycodes without reimplementing xkb in Lua. All of them answer from the seat's own layout, so two seats on different layouts answer differently.

`seat:strokeFor(value)` is the reverse lookup. A string is read as the character to type and a number as a keysym, and the answer prefers the fewest modifiers and then the lowest keycode, so a digit resolves to the number row rather than the keypad. It returns `nil` for anything the layout cannot express — that is what `sink:typeText` is for — and raises on a string of more than one character, because a stroke produces one keysym.

`seat.clipboardBridge` and `seat:setClipboardBridge(bridged)` are the host clipboard's one connection to a seat. The host desktop has one clipboard and one primary selection while every seat has its own, so exactly one seat is bridged: its selections are the host's in both directions, and every other seat's stay inside lunette. Bridging a seat takes the bridge off whichever seat had it, and passing `false` on a seat that is not the bridged one does nothing, so a configuration can call either without first asking which seat holds it. The seat every session starts with is bridged, so a configuration that never mentions the clipboard behaves as a single-seat compositor does. [Input](input.md#clipboard) states the mapping and [Decisions](decisions.md#recorded-decisions) states why it is one seat rather than all of them.

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
function lovr.lunlayergranted(event)  -- event.claim, event.layer.
function lovr.lunlayerrevoked(event)  -- event.claim.
```

Both fire at the boundary the change lands on, before `lovr.update`, so a handler reading `event.claim.granted` agrees with the event it was handed. `lunlayerrevoked` carries no layer because there is none by then. An error raised in either handler is reported and changes nothing: both had already happened before the handler ran.

Revocation does not kill the claim. `claim.granted` goes false and `claim.layer` answers `false`, and the claim takes a layer again as soon as one frees and nothing outranks it — which is what makes the upgrade automatic. A claim is dead only after `claim:release()`, and a dead handle reads its last-known values and answers `false` from its methods.

Releasing is explicit. Nothing releases a claim when its handle is collected, because the grant and revoke events carry a second handle to the same claim and collecting that one would withdraw a live claim. A configuration that drops a panel releases the panel's claim.

## Reload

There are two reload paths, both of which preserve running applications.

`lunette.reload()` performs a soft reload. It clears `package.loaded` for user and standard-library namespaces and re-runs `main.lua`. The LÖVR modules, XR session, GPU objects, compositor, and clients all remain running. The reload is effectively instant, with no visual disruption. It is the default reload path. Iterating on layout code in-headset with sub-second reloads is a significant benefit of this design.

The risk of soft reload is that timers, signal connections, coroutines, and stashed handles from the old configuration persist unless something tears them down. `mullion` provides an explicit teardown hook that soft reload calls to address this. The hooks run first, before anything is cleared, so a hook still has the modules and callbacks it is tearing down. One raising is reported and does not stop the rest, which is the registry's own contract.

The order is: teardown hooks, then the callbacks `main.lua` owns, then `package.loaded`, then `main.lua`, then `lovr.load`. `lovr.load` runs because `main.lua` conventionally defines callbacks and does its setup there, so a reload that ran only the file would install the new callbacks and never run the new setup. It receives the same `arg` it is given at startup.

What survives is stated as roots rather than as a list of what goes, so that a module added later is cleared without the mechanism being updated. `lovr.*` and the interpreter's own modules — `string`, `table`, `math`, `os`, `package`, `coroutine`, `io`, `debug`, `bit`, `jit`, `ffi` — are kept; everything else goes. `crates/lunette/src/reload.rs` is the source of truth for both that set and the callbacks cleared, which deliberately exclude the ones `boot.lua` defines defaults for: `boot.lua` runs once per Lua state, and a soft reload does not make a new one, so clearing `lovr.log` would remove a default nothing would put back.

The Lua state itself is not closed. Globals survive; what goes is what `main.lua` owns. A configuration that must carry something across a reload has the global table and the per-window property store; `lunette.restart()` is the operation that discards everything.

Clearing the callbacks matters for the case the file no longer mentions them. Re-running `main.lua` redefines the callbacks it still defines, but a callback the user *deleted* would otherwise stay bound to the old function and keep being called, so a reload would silently keep executing code that is no longer in the file.

`lunette.reload()` answers `true`, or `false` and a message. It does not raise, and it does not fall into safe mode: safe mode is for a `main.lua` that fails to load at startup, and a reload that fails leaves the session running so the user can fix the file and reload again. A reload that reached `main.lua` and failed there has already torn the previous configuration down, so the session continues with whatever the failed run installed before it raised.

A reload asked for from inside a reload is refused with that message rather than performed. A configuration that reloads as it loads would otherwise recurse until the stack ran out, and taking the process down takes every connected client with it. In practice this means `lovr.load` is not a place to call it from; a key binding or a `lunctl` chunk is.

`lunette.restart()` performs a hard restart, using LÖVR's `lovr.event.restart`. This closes the entire Lua state and rebuilds it, tearing down graphics and the XR session with it. See [LÖVR integration](lovr-integration.md#restart-semantics). The result is a clean slate, with a visible hitch and brief blackness in the headset. It is used when a soft reload is not sufficient.

Wayland clients survive both, because Rust holds the socket outside the Lua state.

## Errors

Every user callback runs under `xpcall` with a traceback. An error is logged, emits `lovr.lunerror`, and displays a floating error panel; execution then continues. Identical repeated errors are rate-limited, so an error recurring every frame does not fill the display.

The handler itself is `mullion` code and can be replaced wholesale, since `lovr.errhand` is overridable. It is `mullion.error`, and the two boundaries it serves are not the same one. A callback that raises is caught at the callback boundary, reported, and the frame continues. An error that escaped every callback boundary reaches `lovr.errhand`, by which point LÖVR has already unwound the frame loop and wants a replacement one back; there is no frame left to continue, so the handler reports and hands the loop decision on.

The native layer owns exactly one failure path: if `main.lua` fails to load, safe mode starts. This is a minimal built-in configuration with a laser, one panel, a way to spawn a terminal, and a reload key. Without this fallback, a configuration error would produce a black headset with no way to recover, requiring the user to remove the headset and edit Lua at a desk every time.

Safe mode is compiled into the binary rather than installed, and `crates/lunette/src/safe_mode.lua` is what it runs. It requires `lunette` and nothing else — never `mullion`, since a broken standard library is one of the reasons `main.lua` may have failed — so it resembles the shipped configuration without sharing code with it. [Decisions](decisions.md#recorded-decisions) records why the duplication is deliberate.

## lunctl

`lunctl` sends a Lua chunk to the running instance over a Unix socket at `$XDG_RUNTIME_DIR/lunette-0.sock`, mode 0600. The chunk is evaluated on the Lua thread between frames within a wall-clock budget, and the result is serialised back.

```console
$ lunctl 'return #lunette.windows()'
3
$ lunctl 'for _, w in ipairs(lunette.windows()) do print(w.appId, w.title) end'
$ lunctl 'mullion.layout.arc(mullion.tag.current())'
```

This is the most significant inheritance from awesome, more significant than any layout algorithm. awesome's design allows the whole window manager to be inspected and mutated from a shell prompt while it runs, which is a substantial part of its usability. `lunctl` also serves as the end-to-end test harness: it spawns a client, evaluates assertions, and tears down.

A caller that wants a typed protocol can build one in Lua on top of this mechanism.

Three things learned from awesome's version (`inspiration/awesome/lib/awful/remote.lua`):

- awesome's remote control is exposed on the session D-Bus, reachable by every process in the session, including Flatpak applications granted `--socket=session-bus`. This makes it possible for a sandboxed application to ask the window manager to run arbitrary Lua. A 0600 socket in `$XDG_RUNTIME_DIR` provides the same capability with a smaller attack surface.
- awesome enables remote control unintentionally. The manpage implies it is opt-in, but `lib/awful/init.lua:28` requires `awful.remote` unconditionally, so every configuration that calls `require("awful")` has arbitrary code execution enabled. lunctl is enabled deliberately, documented as equivalent to root access on the user's session, with a switch to disable it.
- awesome's serialisation is limited to booleans, numbers, and strings; every other value is converted with `tostring`. This is adequate for a REPL but insufficient for tooling. lunctl serialises nested tables, and represents handles as opaque ids.

No network transport is provided.

## Bindings

The API is bound with `mlua`, via `Lua::get_or_init_from_ptr`, attaching to the `lua_State` that LÖVR created. That entry point constructs mlua's view of the state with its `owned` flag clear, so mlua never closes a state it did not create; the boot sequence keeps that responsibility. Hand-written `lua_State` C API calls are reserved for measured hot paths, realistically only per-frame snapshot publication, if profiling shows it is necessary.

This choice is motivated by failure mode, not throughput. A Lua mistake should raise a catchable error rather than crash the window manager, because the premise of this project is that users write Lua that reshapes the system. mlua's per-call cost is negligible relative to the cost of a compositor and a GPU frame.

LuaJIT's FFI remains available to a script that wants to call a C ABI directly, at its own risk. The standard library is not built on it.

The API is available only in the main Lua state. `lovr.thread` and `lovr.task` states do not receive it.
