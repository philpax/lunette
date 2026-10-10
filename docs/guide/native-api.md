# The native API

`require '@lunette'` is the native mechanism under every configuration and plugin: windows, processes, outputs, monitors, input sinks, seats, composition layers, and events. Everything above it, including the shipped desktop, is Lua written against this API and the [plugin contracts](writing-plugins.md). `lua/lunette/init.luau` declares every member with a comment describing it, and an editor that reads the `.luaurc` that `lunette --dump-config` writes resolves `@lunette` to those declarations. [The Lua API](../dev/lua-api.md) is the specification.

## The configuration is a LÖVR project

`main.luau` in the configuration directory is a LÖVR project. It defines LÖVR's callbacks and requires lunette's libraries like any other module, and nothing runs on the user's behalf unless the file defines it. When no configuration exists, lunette runs the shipped one directly, so an unedited configuration never goes stale. A configuration can use `lunette` alone, some of the built-in providers, or the whole `@lunette-desktop` composition.

Every configuration follows these rules:

- Use `lunette` only from the main Lua state, never from `lovr.thread` or `lovr.task`.
- Check `handle.dead` before using a handle kept from an earlier frame. A window can close between any two frames, and a dead handle answers with its last values and refuses every request.
- Never keep the result of `getTexture()` past the frame that returned it. Textures rotate as a client cycles its buffers. `window:stabilize()` returns a texture that persists.
- Treat every mutation as a request. `win:resize(w, h)` asks the client, which may answer later or at another size, and `win:close()` asks the client to close, which it may answer with a prompt or ignore. The new state appears in a later frame's snapshot.
- Subscribe to events through a plugin's `context:on`, so the subscription ends with the plugin. A bare `lunette.on*` call outlives the plugin that made it.
- Raise errors normally rather than catching them to keep a frame alive.

## Windows

`lunette.windows()` returns every mapped toplevel as of this frame. A handle keeps its identity across frames, so it can be stored in a table, compared with `==`, and used as a key. `win.id` is stable for the window's life, including across reloads and restarts.

`win:setProperty(key, value)` keeps a number, string, or boolean with the window outside the Lua state, so it survives a source reload and a hard restart while the window lives. The shipped desktop stores a hand-placed pose there under `lunette.pose`. `getProperty` still answers on a dead handle, so an `onWindowClosed` listener can read what the window stored. Data that must outlive the window belongs in a file keyed by something durable such as `win.appId`.

`win:setFrameRate(hz)` limits how often a client draws, which is how the shipped desktop slows hidden windows. `win.contentType` is the client's own hint, such as `video` or `game`, and `win.commit` changes whenever the client delivers a new buffer.

## Processes and outputs

`lunette.spawn { argv = { 'foot' } }` starts a program as a client of lunette. What it writes to standard output and error goes to lunette's log, and `lunette.onProcessOutput` also delivers it to Lua. Applications started from elsewhere, for example with `WAYLAND_DISPLAY` set to lunette's socket, appear as windows too.

An output is a virtual monitor shown to the clients assigned to it. Every client sees the session's starting output unless it was spawned with `output = lunette.newOutput { ... }`. A client keeps its output for its whole life. `output:setMode { scale = 2 }` changes a live output, and the clients re-render at the new scale. `lunette.scaleSteps()` returns the scales the shipped scale policy chooses between. [Compositor](../dev/compositor.md#outputs) describes outputs in detail.

## Monitors

`lunette.monitors()` returns the user's own screens. `monitor:mirror()` starts capturing one, through wlr-screencopy where the host supports it and otherwise through the desktop portal, which may show a permission dialog. `monitor:getTexture()` returns the latest captured frame, or `false` before the first one. `lunette.selectMonitors()` asks the portal again, for example after the user refused. `monitor.id` is the saved identity: it survives a restart and a move to another port. [Host desktop](../dev/host-desktop.md) describes capture.

## Pointing and typing

A sink receives input in pixel coordinates. `win.sink` reaches a hosted application and `monitor.sink` the host desktop. lunette knows nothing of the 3D scene: Lua intersects a ray with a panel, converts the hit to pixels, and calls `sink:pointer(x, y)` and `sink:button('left', pressed)`. `@lunette-contracts/quad` intersects a flat quad. The built-in interaction and laser providers do all of this for the shipped desktop.

A seat carries one pointer and one keyboard, so two independent cursors need two seats; `lunette.newSeat { name = 'left', layout = 'us' }` makes one with its own keyboard layout. Every sink method takes an optional trailing seat. Pointing does not move keyboard focus: `seat:setFocus(win.sink)` gives a seat's keyboard to a window. A host sink shares the host desktop's one cursor and keyboard, ignores the seat, and cannot take focus. `seat:strokeFor`, `seat:characterFor`, and `seat:symbolFor` answer questions about the seat's layout, which is how a virtual keyboard draws its legends. `sink:typeText(text)` types text the layout cannot express directly, and must not be mixed with `sink:key` on the same seat. One seat at a time exchanges the clipboard with the host desktop; `seat:setClipboardBridge(true)` chooses it. [Input](../dev/input.md) describes seats, routing, and the clipboard.

## Composition layers

A panel is drawn either as a textured quad in lunette's scene or on a composition layer, which the XR runtime samples at native resolution and so shows sharper text. Layers are scarce. `lunette.claimLayer { window = win, width = w, height = h, priority = p }` asks for one, and the highest priorities hold them. A claim is granted no earlier than the next frame, and can be revoked and granted again; `claim.granted` and `claim.layer` say whether it holds one this frame, so neither is kept across frames and both are read every frame. Nothing releases a claim automatically: code that stops showing a window calls `claim:release()`. The built-in panels provider manages claims when its `rendering` option is `layer`.

`lunette.setSceneEnabled(false)` stops lunette rendering its own scene, which saves GPU time when every panel is on a layer. `lovr.draw` is then not called.

## Events

```luau
local cancel = lunette.onWindowOpened(function(event)
  print(event.window.title)
end)
```

Each `lunette.on*` function subscribes a listener and returns the function that cancels it. Payloads are typed, so a handler needs no annotation. An `onWindowClosed` payload carries a dead handle that still reports the window's last title and size. Inside a plugin, `context:on { event = lunette.onWindowOpened, run = handler }` subscribes for the plugin's lifetime. A source reload cancels every subscription.

`lunette.textBoundaries(text)` returns the byte offsets of grapheme cluster boundaries, for editing text one visible character at a time.

## Reloading

`lunette.reload()` reloads the configuration in place. Plugins shut down, every module the configuration and its plugins loaded runs again, and `main.luau` and `lovr.load` run again. Applications, their windows, per-window properties, and the XR session stay. Only plugin cleanup runs, so a module that holds native resources outside a plugin keeps them, and a module must be safe to run twice. A reload that fails leaves what the failed run installed; correcting the file and reloading again recovers. The wrist menu's Reload configuration action calls it.

LÖVR's `lovr.event.restart()` rebuilds the whole Lua state and the graphics device. Applications stay connected; everything held in Lua is lost.

## Errors and safe mode

An error in an event listener, a plugin callback, or a handler registered through the frame contract is logged and shown by the shipped desktop's error display, and the session continues. An error in a `lovr.update` or `lovr.draw` that a configuration assigns itself is not caught and ends the session, so a configuration that assigns those callbacks protects them. `lunette.reportError { context, message }` reports an error through the same path from code that catches one.

If `main.luau` fails to load, lunette starts safe mode, which shows the error on a panel with a laser, a button that opens a terminal, and a reload key. Safe mode is built into the binary, so it works even when the installed Lua files are broken.

## lunctl

`lunctl` evaluates Lua in the running session and prints the result:

```console
$ lunctl 'return #lunette.windows()'
3
$ lunctl 'local titles = {} for _, w in ipairs(lunette.windows()) do titles[#titles + 1] = w.title end return titles'
```

A chunk returns what it wants shown: `print` writes to the session's standard output, not to `lunctl`. It takes chunks as arguments, on standard input, or at an interactive prompt; `rlwrap lunctl` adds line editing. A chunk sees the session's globals and loaded modules, so `lunette` names `@lunette`, and a global it assigns persists for later chunks. A handle prints as its kind and identity, such as `<window 3>`. `lunctl --help` lists the exit statuses that scripts can test. The socket is private to the user, and `LUNETTE_CONTROL=off` in the session's environment disables it. Anything that can reach the socket controls the session.
