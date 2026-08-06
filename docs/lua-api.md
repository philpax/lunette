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

The native layer pushes events through LÖVR's own event queue, so lunette events interleave with `lovr.keypressed` and other LÖVR callbacks in a defined order. Callbacks are prefixed `lun`:

```lua
function lovr.lunwindowopened(win) end
function lovr.lunwindowclosed(win) end
function lovr.luntitlechanged(win, title) end
function lovr.lunmonitoradded(mon) end
function lovr.lunprocessexited(proc, code) end
function lovr.lunprocessoutput(proc, stream, text) end
function lovr.lunlayergranted(claim, layer) end
function lovr.lunlayerrevoked(claim) end
function lovr.lunerror(err, traceback) end
```

The prefix occupies LÖVR's callback namespace permanently and is chosen to be distinctive: `lovr.lun*` is unlikely to collide with any callback added upstream.

`boot.lua`'s poll loop unpacks four arguments, so richer payloads travel as a table.

Signals are implemented in Lua. The native layer pushes flat events; `mullion` builds `connect_signal`, `emit_signal`, property-change signals, and per-window signal tables on top of them. awesome's signal system is approximately 100 lines of Lua, an amount of machinery small enough to leave replaceable.

## Handles

Window, monitor, process, seat, output, and claim handles are persistent objects with stable identity, refreshed at frame start. See [Architecture](architecture.md#handles) for the model and for why dead handles go inert rather than raising.

Reads are snapshot fields. Mutations are requests:

```lua
print(win.title)             -- last frame's value.
print(win.appId)             -- the client's application identifier.
print(win.width, win.height) -- the surface's size in pixels.
win:resize(1920, 1080)       -- a configure request; the client may ignore it.
win:close()                  -- returns nothing; watch for lovr.lunwindowclosed.
```

`win.width` and `win.height` are pixels, and report the size the client last committed rather than the size last requested of it. They are part of the native surface rather than something the standard library derives, because converting a ray hit on a panel into a pixel coordinate for `sink:pointer` needs them, and `mullion` reaches for nothing the public API does not expose.

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
