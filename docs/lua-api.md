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
```

`win:close()` sends the xdg-toplevel close request. The client decides what to do with it: an editor with unsaved work puts up a prompt, and a client is free to ignore it entirely. The window goes when the client unmaps it, which arrives as `lovr.lunwindowclosed`.

`win:resize(width, height)` configures the toplevel. The client resizes at its own pace, and `win.width` and `win.height` change when it commits a buffer — which may be at a different size, because a client is free to honour its own minimum or to round to a character cell. Nothing waits for that. The dimensions are whole pixel counts of at least one, and a value that is not raises.

Both return `false` on a dead handle, without raising. Both are requests, so neither reports what the client did; that arrives as an event or as a changed snapshot field.

`win:stabilize()` is described in [Rendering](rendering.md#windowstabilize).

`win.opaque` reports that the window's current buffer has no alpha channel, so its fourth component is padding a caller forces to one rather than sampling. It is a property of the buffer and changes when the client renegotiates its format, so it is read each frame alongside the texture. [Rendering](rendering.md#alpha) states what a consumer does with it, and why premultiplied blending is the other half of the same subject.

`win.width` and `win.height` are pixels, and report the size the client last committed rather than the size last requested of it. They are part of the native surface rather than something the standard library derives, because converting a ray hit on a panel into a pixel coordinate for `sink:pointer` needs them, and `mullion` reaches for nothing the public API does not expose.

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

`monitor:setPaused(paused)` is the middle case, for a panel that has left the user's view. The stream stops producing but is not given up, so resuming costs nothing. Reach for `dismiss` when the user closed the panel, and for `setPaused` when they merely turned away.

`lovr.lunmonitoradded` fires for each monitor at startup and for each one attached afterwards. It carries `event.id`, and `event.monitor` when the screen is still attached by the time the handler runs.

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

The risk of soft reload is that timers, signal connections, coroutines, and stashed handles from the old configuration persist unless something tears them down. `mullion` provides an explicit teardown hook that soft reload calls to address this.

`lunette.restart()` performs a hard restart, using LÖVR's `lovr.event.restart`. This closes the entire Lua state and rebuilds it, tearing down graphics and the XR session with it. See [LÖVR integration](lovr-integration.md#restart-semantics). The result is a clean slate, with a visible hitch and brief blackness in the headset. It is used when a soft reload is not sufficient.

Wayland clients survive both, because Rust holds the socket outside the Lua state.

## Errors

Every user callback runs under `xpcall` with a traceback. An error is logged, emits `lovr.lunerror`, and displays a floating error panel; execution then continues. Identical repeated errors are rate-limited, so an error recurring every frame does not fill the display.

The handler itself is `mullion` code and can be replaced wholesale, since `lovr.errhand` is overridable.

The native layer owns exactly one failure path: if `main.lua` fails to load, safe mode starts. This is a minimal built-in configuration with a laser, one panel, a way to spawn a terminal, and a reload key. Without this fallback, a configuration error would produce a black headset with no way to recover, requiring the user to remove the headset and edit Lua at a desk every time.

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
