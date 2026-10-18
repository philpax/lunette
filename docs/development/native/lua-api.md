# Native Lua API

`@lunette` exposes native mechanisms in the main Luau state only. [Generated declarations](../../../lua/lunette/init.luau) own names and types; Rust registration generates them. Binding changes update the registration and generator, not a hand-written stub. Configuration examples belong in [the native API guide](../../plugins/native-api.md), and plugin ownership belongs in [the facade](../../../lua/lunette-plugin/README.md).

## Handles

Each read returns fresh userdata. Equality compares native identity, but table keys use raw userdata identity; use an object's id as a key. Queued objects remain dead until a frame snapshot contains them. Dead handles retain observed fields and refuse mutations without raising, because disappearance between frames is ordinary. [Snapshots](../architecture.md#the-snapshot-model) define timing.

Textures from window, monitor, child-surface, and drag handles last only the current frame. A session-wide commit stamp detects installed content; texture identity cannot, because clients reuse buffers. [Persistent copies](rendering.md#texture-import-and-lifetime) are explicit. Geometry and pointer positions use surface coordinates and source crop, not texture dimensions.

Process handles name logical registrations, not reusable PIDs. Registration can lag a queued spawn; windows need not have a process association, and a process can outlive its windows. Layer claims and audio readers require explicit release or close; garbage collection does not release them.

## Events

Native events interleave with LÖVR events in queue order and observe the snapshot of the frame that drains them. Listeners run in subscription order under independent protected calls. A close event carries a dead handle with its last values. Source reload clears subscriptions. Event payloads and subscription declarations originate in `crates/lunette/src/events/`.

## Audio capture

[Audio](audio.md) owns format, attribution, source state, and publication guarantees. Source validation rejects raw PIDs, foreign-session handles, unknown fields, and metatables before acquisition. A same-session queued spawn is valid and remains starting until registration resolves. Outages preserve source identity rather than choosing replacement audio.

Close is idempotent and independent per reader. Retained PCM blocks are immutable and survive close; copied buffers are independent. Empty blocks alone establish neither silence nor unavailability. PCM cannot be returned through `lunctl`.

## Per-window properties

The native scalar property store survives reload and restart while the window lives. It rejects tables and non-finite numbers. Dead handles can read properties during close delivery; disk persistence remains Lua policy.

## Reload

`lunette.reload()` closes plugin runtimes, retires the contract epoch, clears subscriptions and callbacks, removes unprotected loaded modules, and runs the replacement configuration. Lua globals, LÖVR, graphics, clients, and native state remain. Only plugin effects provide cleanup. The [implementation](../../../crates/lunette/src/reload.rs) owns protected modules and cleared callbacks; module bodies must tolerate running again.

Named seats can transfer through [native handover](input.md#seat-lifetime), and mirrors remain held until loading finishes. Reload returns success or a message rather than raising and refuses nesting and plugin callbacks. It is not transactional: failed evaluation leaves partial replacement state. Startup safe mode does not recover a failed reload.

`lovr.event.restart()` coalesces requests until callbacks return, then replaces Lua and graphics. Clients survive. [Restart ordering](lovr-integration.md#restart-semantics) is required to avoid device use-after-free.

## Errors

Native listeners, plugin initializers, and inverses use protected calls. Lua dispatchers must protect handlers independently and report failures through `lunette.reportError`; this logs a traceback and delivers it to error listeners without rate limiting. Re-raising stops later handlers, and logging alone bypasses presenters.

The host does not protect raw LÖVR callbacks. An uncaught callback error reaches `boot.lua` and normally ends the process with status 1. Returning the previous loop from `lovr.errhand` skips the failed frame's remaining work, including submission; it is not complete XR recovery.

Compiled-in safe mode replaces callbacks after initial configuration failure, including mount, syntax, top-level, and load errors. `lunette.restartIntoSafeMode` queues a hard restart whose next boot runs safe mode instead of the configuration's `main` module; the request lives on the native session and covers that one boot. It needs no installed plugin roots, so a broken installation cannot remove recovery. A loaded graphics module whose initialization fails cannot render recovery; the host logs the startup error and exits with status 1 without starting safe mode. Safe mode does not protect arbitrary runtime callbacks or clean up module-owned resources outside plugins.

## lunctl

`lunctl` evaluates chunks on the Lua thread between frames. Its local socket grants full session authority. The runtime directory must be private before binding; changing socket permissions afterward leaves a connection window. There is no network transport. `LUNETTE_CONTROL` enables it only when unset, empty, or `on`, so other values fail closed.

Evaluation time limits are best-effort Luau interrupts. Interpreted and generated Luau code check safepoints, but a chunk can catch the error, and a C function may never return to a safepoint. A hard watchdog would kill the session and its clients, so none is supplied. The control socket is not a sandbox.

Serialization rejects cycles, unsupported values, and non-scalar keys instead of substituting strings. Traversal is raw and bounded; handle results contain kind and session identity, never addresses. [The control implementation](../../../crates/lunette/src/control/) owns the wire format.
