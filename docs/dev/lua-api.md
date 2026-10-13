# Native Lua API

`require '@lunette'` exposes native session mechanisms to the main Luau state. The [generated declarations](../../lua/lunette/init.luau) own member names, types, and argument shapes. [The native API guide](../guide/native-api.md) gives configuration examples. [Module roots](build-and-development.md#module-roots) specifies resolution.

The [plugin facade](../../lua/lunette-plugin/README.md) and [service contracts](../../lua/lunette-contracts/README.md) have separate specifications. Native mechanisms remain usable without the shipped plugins. The [architecture](architecture.md) specifies threads, snapshots, ownership, and the native plugin graph.

## Handles

Native handles identify session objects. Reads return fresh userdata, and `==` compares the objects they name. Table keys use raw userdata identity, so a table indexed by object uses its id instead. A queued seat, output, or process remains dead until a frame snapshot contains it. A dead handle retains its last observed fields; a mutation on it returns `false` without effect. [Architecture](architecture.md#the-snapshot-model) specifies asynchronous requests and snapshot timing.

A surface's commit counter is session-wide, never reused, and zero before its first buffer. Texture identity cannot establish whether a client drew: textures last one frame, and clients reuse buffers. `window:getTexture()` and `monitor:getTexture()` are valid only in the current frame. [Rendering](rendering.md#texture-import-and-lifetime) specifies the persistent copy from `window:stabilize()`.

Window dimensions and input coordinates use surface coordinates, which may differ from texture dimensions. A renderer samples the source crop rather than assuming the whole buffer. Popup and subsurface records use coordinates relative to the window and bottom-first ordering; a popup can extend outside it. Their textures have the same frame lifetime as the window texture. A dead window has no child records. [Compositor windows](compositor.md#windows) specifies geometry and buffer transforms, and [decorations](compositor.md#decorations) specifies client decoration mode.

A drag handle names one drag, not a reusable seat slot. It ends when the drag drops or is cancelled. An iconless drag has zero geometry and no texture or stabilised copy. [Compositor drag and drop](compositor.md#drag-and-drop) specifies native drag state; [input](input.md#drag-and-drop) specifies sink delivery.

A monitor's `mirrored` flag reports an installed stream, not continuing frame arrival. [Host desktop](host-desktop.md#identity-and-lifecycle) specifies capture lifecycle and its limits.

## Events

Native events travel LÖVR's event queue and interleave with its callbacks in queue order. Subscription functions return a cancellation function. Listeners run in subscription order, each under a protected call. [Event declarations](../../crates/lunette/src/events/mod.rs) generate subscription functions and typed payloads.

Delivery observes the snapshot of the frame that drains the event. `onWindowClosed` therefore supplies a dead handle with the window's last values. A process that never starts is reported only through `onProcessExited`. Source reload clears all native subscriptions.

## Processes

Process handles name logical session registrations, not reusable host PIDs. A queued spawn is not listed until registration. A window can have no process association, and a dead window retains its last-known association. A process may stay live after its windows close. [Compositor processes](compositor.md#processes) specifies registration and attribution; [audio attribution](audio.md#process-attribution) specifies instance-safe capture.

`Process.id` is a non-zero integer represented exactly as a Luau number. Managed ids increase from 1 through `2^52 - 1`; adopted ids decrease from `2^53 - 1` through `2^52`. They do not overlap or repeat within the session. Managed exhaustion raises before queuing a spawn; adopted exhaustion rejects the connecting client before registration.

## Audio capture

`lunette.openAudio` opens an independent non-routing reader. Source descriptors must be plain tables without metatables. Unknown fields, raw PIDs, non-process userdata, and foreign-session handles raise before acquisition. A same-session queued spawn is valid despite its dead handle: capture stays `starting` until registration succeeds or ends. An ended source does not select a replacement. [Audio](audio.md) specifies format, source states, attribution, sharing, and publication bounds.

A reader becomes dead only after explicit close or a terminal source outcome. Starting, idle, and unavailable readers stay live. `close()` is idempotent; garbage collection does not release a reader. Closing one reader does not close another for the same source. A closed or missing reader returns an ended, empty snapshot retaining its original source.

Snapshots and native PCM blocks are immutable. A process source supplies a fresh process handle in each snapshot. Empty blocks establish neither silence nor unavailability. Retained blocks stay readable across frames and after reader close. Sample time is cumulative within a stream generation, not a device timestamp. `copySamples()` allocates a separate mutable buffer; changing it cannot change native PCM or another copy. Copies are explicit, and consumers bound their own work. The [audio guide](../guide/native-api.md#audio-capture) demonstrates reading PCM.

The [native registration](../../crates/lunette/src/lua/audio.rs) owns declaration shapes, using the neutral [audio vocabulary](../../lua/lunette-contracts/audio.luau). An audio reader has a control-wire identity; PCM blocks and buffers cannot be returned through `lunctl`.

## Per-window properties

The native property store holds scalar values outside Lua, keyed by window id. Values survive source reload and hard restart while the window lives. Tables and non-finite numbers raise. A dead handle can still read its properties during `onWindowClosed`; entries end when the window closes. Disk persistence is Lua policy.

Window ids remain stable across reload and restart because the compositor survives both. [Restart semantics](lovr-integration.md#restart-semantics) specifies host lifetime.

## Layer claims

A claim stays live after revocation and can receive a layer again. Only `release()` ends it; garbage collection does not, because other handles can name the same claim. Requested sizes, priority arbitration, and frame-boundary grants are specified by the [layer pool](rendering.md#layer-allocation). Native claims take windows, not monitors.

## Scene rendering

`lunette.setSceneEnabled(false)` stops `lovr.draw` at the next frame boundary while the headset frame and composition layers continue. The value survives source reload. The configuration owns scene contents and decides whether to skip them. [Scene skipping](rendering.md#frame-pacing-and-scene-skipping) specifies the mechanism.

## Reload

Source reload and hard restart keep applications connected because the compositor owns the Wayland socket outside Lua. Plugin instance reload replaces one activation instead. [Lifecycle survival](architecture.md#survival-across-lifecycle-events) records which resources remain.

`lunette.reload()` shuts down plugin runtimes and retires their contract epoch, clears native subscriptions and configuration callbacks, removes unprotected `package.loaded` entries, and runs `main.luau` followed by `lovr.load` with the startup `arg`. The Lua state, globals, LÖVR modules, XR session, GPU objects, compositor, and clients remain. [The reload implementation](../../crates/lunette/src/reload.rs) owns the protected module roots and cleared callback list. Only plugin effects provide cleanup.

Mirrors and seats outlast the closing configuration until the replacement loads. [Seat lifetime](input.md#seat-lifetime) specifies named seat handover, reset, and destruction when the replacement takes no ownership.

`lunette.reload()` returns `true`, or `false` and a message, and never raises. It refuses nested reloads and calls from plugin callbacks. Failure after `main.luau` starts leaves what the failed run installed; safe mode applies only at startup.

`lovr.event.restart()` requests a hard restart after the frame's callbacks return. Requests in one frame coalesce. The host closes plugin runtimes and clears native subscriptions before the Lua state closes. [LÖVR integration](lovr-integration.md#restart-semantics) specifies the remaining teardown.

## Errors

Native listeners, plugin initializers, and plugin inverses run under protected calls. A Lua dispatcher can protect a handler and report its failure through `lunette.reportError`. The [native error boundary](../../crates/lunette/src/callback_error.rs) logs a traceback and delivers it to `lunette.onError` listeners without rate limiting. Dispatchers must protect each handler independently to continue with later handlers. [Plugin runtime](architecture.md#plugin-runtime) specifies failure attribution and waiting diagnostics.

The host does not protect LÖVR callbacks. An uncaught callback error reaches `boot.lua` and, without a configuration-supplied `lovr.errhand`, ends the process with status 1. Returning the previous loop from `lovr.errhand` skips the rest of the failed frame, including submission. Host recovery would need a protected call per callback and would still have to finish any XR frame begun before the error.

Safe mode starts when the initial configuration fails to load. Its `lovr.boot` boundary covers mount failure, missing `main.luau`, a raising `conf.luau`, syntax and top-level errors, and a raising `lovr.load`. It replaces the failed configuration's callbacks and supplies an error panel, pointer, terminal launcher, and reload key. [The compiled-in implementation](../../crates/lunette/src/safe_mode.luau) requires only the native API and tries another terminal only after a spawn failure.

## lunctl

`lunctl` evaluates a Lua chunk on the session's Lua thread between frames and returns the result. Its Unix socket is `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600, inside a directory created at 0700. The directory enforces access: a socket inode starts with `0777 & ~umask`, and `fchmod` on its descriptor does not reach the inode. Changing permissions after bind would leave a connection window. Startup checks `$XDG_RUNTIME_DIR` for the same property. There is no network transport.

A free name resolves first from globals, then loaded modules, trying it as written and with `@`. An assigned name becomes a global for later chunks. [Exit codes](../../crates/lunette/src/bin/lunctl.rs) distinguish evaluation outcomes, unrepresentable results, an unreachable or non-evaluating session, and usage errors.

Only an unset, empty, or `on` value of `LUNETTE_CONTROL` enables the socket. Other values disable it. This fails closed for a misspelt `off`. The socket grants the user's full session authority; it is not restricted to plugin operations.

A Luau interrupt raises after the time budget at the next safepoint. A chunk can catch it with `pcall`, and native code may reach no safepoint. The budget is therefore best-effort. A hard watchdog would terminate the session and every client, so none is supplied.

Serialisation rejects functions, coroutines, foreign userdata, non-scalar keys, and cycles, naming the path. It never falls back to `tostring`. Traversal is raw, shared subtables are duplicated, and a node cap bounds the result. An oversized reply returns `Reply::Oversized` rather than closing the connection. Handles serialise as kind and session identity, never an address.

## Language binding

`mlua` creates and owns the session's Luau state; LÖVR steps the same state through raw C entry points. The API exists only in the main state, not `lovr.thread` or `lovr.task`. Luau has no FFI, so configurations reach native code through LÖVR and `lunette`.

## Decisions

Luau supports static checking while `mlua` makes Lua mistakes catchable errors. LuaJIT is not a build mode because it cannot parse the annotations. Each native member is declared beside its Rust registration, and `LuauType` generates its type. A hand-written stub was rejected because nothing would keep it consistent.

Subscriptions allow several listeners and type their payloads. Assigning a `lovr.lun*` callback or a module field would give each event one slot. State already read each frame, such as titles and layer grants, has no redundant change event. A drag is likewise read through its seat; its handle guards frame-lived icon textures. Raw userdata equality was rejected because repeated reads of one object produce different wrappers.

`lunette.reportError` connects dispatcher failures to the same reporting boundary as native callbacks. Logging alone would bypass presenters; re-raising would stop later handlers. Safe mode is compiled in so a broken installation cannot remove recovery. It wraps startup rather than replacing the configuration's error handler, and uses native mechanisms without depending on installed plugins.

Per-window properties stay native because reload recreates configuration locals. Arbitrary Lua serialisation was rejected because functions, coroutines, and handles cannot survive it. Grapheme segmentation is also native mechanism: `unicode-segmentation` supplies the extended rules, while editing policy stays in Lua.

Remote Lua evaluation retains the configuration's full capabilities over a local, permission-restricted socket rather than adding a separate D-Bus operation interface. Rejecting unrepresentable values preserves errors that a `tostring` fallback would conceal.

## Known gaps

Native event names use `lun*` in LÖVR's namespace; a future LÖVR event could collide. Source reload and hard restart provide no cleanup for modules outside the plugin runtime. Control-socket access permits arbitrary actions with the user's session authority, and its evaluation budget cannot enforce a hard bound.
