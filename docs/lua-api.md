# The Lua API

## Two roots

```lua
local lunette = require 'lunette'   -- native mechanism.
local mullion = require 'mullion'   -- the Lua standard library, optional.
```

Two names because they carry different promises. `lunette` is surfaces, textures, sinks, seats, outputs, processes, layers, clipboard, and capture — implemented in Rust, and the whole of what the system can do. `mullion` is panels, layouts, rules, signals, keybindings, and chrome — implemented in Lua, installed as readable files, and replaceable.

awesome makes the same split by name (`awesome`/`client`/`screen` versus `awful`), and it's why "write your own `awful`" is an obviously available move there. Nesting the standard library under `lunette.*` would read like one API where half of it happens to be Lua.

They're usable independently. `mullion` is written against the same public `lunette` API a downstream user has. If it ever needs something private, the API is wrong.

## The config

`~/.config/lunette/main.lua` is a LÖVR project. It defines `lovr.draw`, `lovr.update`, and the rest; it `require`s our libraries like any other. Nothing is hidden, and no loop is owned on your behalf.

If it doesn't exist, `$SYSCONFDIR/xdg/lunette/main.lua` is used directly — awesome's approach, which avoids stale copies of a config you never edited. `lunette --dump-config` gives you a copy to start editing.

A config that never mentions `mullion` is a supported configuration.

## Events

Native pushes through LÖVR's own event queue, so lunette events interleave with `lovr.keypressed` and friends in a defined order. Callbacks are prefixed `lun`:

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

The prefix squats in LÖVR's callback namespace permanently, which is why it's distinctive: `lovr.lun*` is unlikely to collide with anything upstream adds.

`boot.lua`'s poll loop unpacks four arguments, so richer payloads travel as a table.

**Signals live in Lua.** Native pushes flat events; `mullion` builds `connect_signal`/`emit_signal`, property-change signals, and per-window signal tables on top. awesome's signal system is about 100 lines of Lua, which is the right amount of machinery to leave replaceable.

## Handles

Window, monitor, process, seat, output, and claim handles are persistent objects with stable identity, refreshed at frame start. See [Architecture](architecture.md#handles) for the model and for why dead handles go inert rather than raising.

Reads are snapshot fields. Mutations are requests:

```lua
print(win.title)          -- last frame's value.
win:resize(1920, 1080)    -- a configure request; the client may ignore it.
win:close()               -- returns nothing; watch for lovr.lunwindowclosed.
```

## Reload

Two paths, both preserving your applications:

**`lunette.reload()` — soft.** Clears `package.loaded` for user and standard-library namespaces and re-runs `main.lua`. The LÖVR modules, XR session, GPU objects, compositor, and clients all stay up. Effectively instant, no visual disruption. This is the default, and iterating on layout code in-headset with sub-second reloads is the single biggest quality-of-life feature available to us.

The risk is the classic hot-reload footgun: timers, signal connections, coroutines, and stashed handles from the old config persist unless something tears them down. `mullion` provides an explicit teardown hook that soft reload calls.

**`lunette.restart()` — hard.** LÖVR's `lovr.event.restart`, which closes the entire Lua state and rebuilds it, tearing down graphics and the XR session with it ([LÖVR integration](lovr-integration.md#restart-semantics)). Clean slate, visible hitch, brief blackness in the headset. Use when soft isn't enough.

Wayland clients survive both, because Rust holds the socket outside the Lua state.

## Errors

Every user callback runs under `xpcall` with a traceback. An error logs, emits `lovr.lunerror`, and shows a floating error panel — then execution continues. Identical repeated errors are rate-limited, so a per-frame error doesn't fill your view.

The handler itself is `mullion` code and can be replaced wholesale, since `lovr.errhand` is overridable.

Native owns exactly one failure path: **if `main.lua` fails to load, safe mode starts.** A minimal built-in config with a laser, one panel, a way to spawn a terminal, and a reload key. A black headset with no way to recover means taking the HMD off and editing Lua at a desk, every time.

## lunctl

`lunctl` sends a Lua chunk to the running instance over a Unix socket at `$XDG_RUNTIME_DIR/lunette-0.sock`, mode 0600. It's evaluated on the Lua thread between frames with a wall-clock budget, and the result is serialised back.

```console
$ lunctl 'return #lunette.windows()'
3
$ lunctl 'for _, w in ipairs(lunette.windows()) do print(w.appId, w.title) end'
$ lunctl 'mullion.layout.arc(mullion.tag.current())'
```

This is the awesomewm inheritance that matters most — more than any layout algorithm. The reason awesome is pleasant is that the whole WM is inspectable and mutable from a shell prompt while it runs. It's also our end-to-end test harness: spawn a client, eval assertions, tear down.

Anyone who wants a typed protocol can build one in Lua on top of this.

Three things learned from awesome's version (`inspiration/awesome/lib/awful/remote.lua`):

- **awesome's is on the session D-Bus**, reachable by everything in your session — including Flatpak apps granted `--socket=session-bus`, making "sandboxed app asks your WM to run Lua" a live path. A 0600 socket in `$XDG_RUNTIME_DIR` has the same power with a much smaller blast radius.
- **awesome enables it by accident.** The manpage implies it's opt-in, but `lib/awful/init.lua:28` requires `awful.remote`, so every config that does `require("awful")` has arbitrary code execution on. Ours is enabled deliberately, documented as "this is root on your session", with a switch to disable.
- **awesome's serialisation is threadbare** — booleans, numbers, strings, everything else `tostring`'d. Fine for a REPL, useless for tooling. We serialise nested tables, and handles as opaque ids.

No network transport, ever.

## Bindings

The API is bound with **`mlua` via `init_from_ptr`**, attaching to the `lua_State` LÖVR created. Hand-rolled `lua_State` C API is reserved for measured hot paths — realistically only per-frame snapshot publication, if it ever appears in a profile.

The reason is the failure mode, not throughput. A Lua mistake should raise a catchable error, not segfault your window manager, because the premise of this project is that users write Lua that reshapes the system. mlua's per-call cost is irrelevant next to a compositor and a GPU frame.

LuaJIT's FFI stays available to users who want to call a C ABI directly at their own risk. We just don't build the standard library on it.

The API is **main-Lua-state only**. `lovr.thread` and `lovr.task` states don't get it.
