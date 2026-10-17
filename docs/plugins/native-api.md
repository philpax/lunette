# The native API

Plugin code imports `@lunette` for windows, capture, input, and other native session mechanisms. The [generated declarations](../../lua/lunette/init.luau) own the API inventory and appear in editors through the `.luaurc` written by `lunette --dump-config`. [The Lua API specification](../development/native/lua-api.md) owns native behavior; [service contracts](../../lua/lunette-contracts/README.md) describe the Lua services above it.

## Handle and resource lifetimes

Use `lunette` only in the main Lua state, not in `lovr.thread` or `lovr.task`. Check `handle.dead` before using a handle retained from another frame. Dead handles keep their last values and refuse requests.

Mutations are requests, not immediate state changes. A client may resize later or refuse closure. Read the later frame snapshot rather than assuming the request succeeded.

Acquire resources inside plugin activation and register their inverses through [context effects](../../lua/lunette-plugin/ownership.md). Native event subscriptions return cancellation functions; `context:on` owns them for the activation. Garbage collection is not a resource-release protocol.

## Windows and textures

Window handles preserve identity while the window lives. Per-window properties survive source reload and Lua restart, but not window closure; longer-lived data needs persistent storage.

Never cache `window:getTexture()` across frames: client buffers rotate. `window:stabilize()` provides a persistent texture. Direct renderers must apply the source crop and draw child surfaces separately. Window input coordinates use client size, which can differ from texture size. The [panels provider](../../lua/lunette-plugins/panels/service/README.md) handles these details for consumers.

## Processes and outputs

A process handle identifies a session registration, not a reusable host PID. Several windows can share a process, and closing one does not necessarily end it. A queued spawn's handle is dead until the compositor observes it.

A client keeps its assigned virtual output for its lifetime. Output mode changes ask clients to render at the new scale. See [outputs](../development/native/compositor.md#outputs) for native constraints.

## Audio capture

Audio readers capture without changing playback routing. They never substitute a different source after an outage. A frame exposes one immutable publication; read it once per publication rather than processing it again in each callback.

Retained PCM blocks remain valid after later frames and reader closure. Copying samples allocates a mutable buffer; bound the work per update. Generation changes, gaps, and dropped frames invalidate accumulated analysis history. Closing a reader is explicit and idempotent. [`examples/audio-backdrop`](../../examples/audio-backdrop) shows owner-scoped readers; [Audio](../development/native/audio.md) defines PCM format and queue bounds.

## Monitors

Capture may require portal screen-sharing permission and has no texture before the first frame. Consumers must handle refusal, capture loss, and monitor removal. The [monitor plugin](../../lua/lunette-plugins/panels/monitors/README.md) describes restart and reselection controls.

## Pointing and typing

Native sinks accept pixels, not scene rays. Independent native cursors require separate seats. Pointing does not transfer keyboard focus. A host sink shares the host desktop's cursor and cannot take its keyboard focus.

Do not mix `sink:typeText` and held-key delivery on the same seat. Use the [focus and interaction contracts](../../lua/lunette-contracts/docs/input.md) when composing local controls and application input; they preserve releases on the original target and prevent stale text reaching a new route.

## Composition layers

A layer claim can be granted, revoked, and granted again. Read its grant and layer each frame; neither may be cached. Release the claim when its content stops being shown. The [panels provider](../../lua/lunette-plugins/panels/service/README.md) owns claims for its panels. Disabling scene rendering also suppresses `lovr.draw`.

## Reloading

Source reload runs loaded modules again while applications, windows, window properties, and the XR session remain. Only plugin cleanup runs. A failed reload can leave partial state; correcting the files and reloading again can recover. LÖVR restart rebuilds the Lua state and graphics device while applications stay connected.

## Errors and safe mode

Raise errors normally. Event listeners, plugin callbacks, and frame-service handlers have protected boundaries. A configuration's directly assigned LÖVR callbacks do not; uncaught update or draw errors end the session. [Errors](../development/native/lua-api.md#errors) states the boundaries. A load failure starts built-in safe mode with error display and recovery controls, and `lunette.restartIntoSafeMode` restarts a running session into it.

## lunctl

`lunctl 'return #lunette.windows()'` evaluates in the running session. Return values go to the caller; `print` goes to the session log. Chunks share session globals, so assignments persist. The user-private control socket grants full session authority; `LUNETTE_CONTROL=off` disables it. `lunctl --help` owns command options and exit statuses.
