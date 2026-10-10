# Architecture

## Process and thread structure

lunette is a single Rust binary that dynamically links LÖVR, which ships beside it as `liblovr.so` ([Build and development](build-and-development.md#building)). Rust owns `main()`.

| Thread | Owns | Communicates with |
|---|---|---|
| Main | The LÖVR Lua state, the headset backend and session, GPU submission, and rendering | The compositor and control threads by channel |
| Compositor | The Wayland display, smithay state, clients, surfaces, seats, and child processes | The main thread by channel; creates images on LÖVR's `VkDevice` |
| Control | The `lunctl` Unix socket | The main thread, which runs submitted chunks between frames |

`wlx-capture` owns further threads for capture and PipeWire.

Rust hosts LÖVR because a window manager has lifecycle requirements that precede and outlast graphics initialisation: a Wayland socket, child processes, PipeWire and D-Bus connections, a control socket, and session state that survives a GPU reinitialisation. In return, lunette is responsible for LÖVR access. It boots the standard LÖVR Lua environment through its own `boot.lua`, and a LÖVR module that does not work under lunette is a defect.

## Compositor thread placement

WayVR ticks its compositor on the main thread once per frame. lunette runs the compositor on its own thread instead. An overlay must not disturb the application beneath it, and a slow operation in compositor dispatch, such as a burst of client requests, a D-Bus round trip, a process spawn, or a stalled `wl_display` write, would otherwise consume part of the frame budget.

## The snapshot model

Lua reads window state as a per-frame snapshot, and every mutation is a request.

- `win.title` is a field on a handle, refreshed at the start of each frame.
- `win:close()` returns nothing. Completion is observed when the window stops appearing.
- `win:resize(w, h)` is a configure request. The client may ignore it, clamp it, or apply it several frames later.

This follows Wayland, which is asynchronous. awesome makes the same arrangement with X11: properties are cached, requests are asynchronous, and results arrive as events.

## Handles

A window handle is a persistent Lua object with stable identity. The native layer refreshes its fields at the start of each frame, so `win == lunette.windows()[1]` compares identity and tags, rules, and listeners can refer to a window observed on an earlier frame.

When a window closes, Lua may still hold its handle. Reads return the last known values, `win.dead` becomes `true`, and methods return `false` without effect. Raising on access was rejected because a window disappearing between frames is ordinary in a compositor, and an error would let that race terminate the session.

## Ownership rules

The compositor and session own native state independently of the Lua state. Handles are recreated when a hard restart creates a new Lua state, and Wayland clients remain connected.

The plugin attachment is the one place where Rust holds Lua values. It stores plugin definitions, callbacks, service values, and cleanup effects for the current Lua state. Each attachment context carries a runtime, instance, and activation identity, and the host rejects operations from an expired activation. Source reload and hard restart close every plugin runtime before they clear modules or close the Lua state.

The `lunette` API and the plugin attachment exist only in the main Lua state. `lovr.thread` and `lovr.task` states do not receive them.

## Plugin runtime

A Lua state owns one plugin attachment and one contract epoch. The attachment creates independent runtime graphs. Definitions and contract tokens are shared within the state; instances, services, effects, and configuration values belong to one runtime graph. [Plugin authoring](lua-api.md#plugin-authoring) specifies the Lua surface.

A contract has an authority-qualified name and a positive schema number. A capability wraps the native token for that identity, and a definition declares the capabilities it requires and provides. Luau checks each service shape and configuration type locally. The runtime validates the graph: it rejects undeclared capability access, absent providers, duplicate or missing provisions, nil values, and publication after the initializer returns. The graph matches a consumer to a provider by exact name and schema and binds it to that provider's generation. A generation derives from the provider's load activation, and every load attempt takes a fresh activation, including failed and cancelled ones. The facade publishes each service as a view that raises once the provider's activation has ended ([Services](lua-api.md#services)).

Initializers and cleanup callbacks run synchronously and do not yield. Provided services stay private until the initializer succeeds and every required provider generation is still active; the graph then publishes the instance's services together. A failed or cancelled initializer publishes nothing and runs its registered cleanup effects in reverse order. A child installed during an activation belongs to that activation and is retired when it ends. A retired instance cannot be enabled again.

The graph in `crates/lunette/src/plugin/graph/` is a pure core: it holds lifecycle state, accepts intents, plans one load or unload at a time, and records diagnostics. The attachment in `crates/lunette/src/plugin/attachment/` performs those actions against Lua. An intent changes graph state at once and returns any rejection to its caller. Planning derives from state, so there is no intent queue: a drain sees requests made during it. A drain stops with an error after an action budget proportional to the largest instance count it has seen, and the next drain resumes. A closing runtime keeps its records until the graph is empty, so an interrupted close resumes.

An instance reserves the contracts it provides, keyed by name and schema, from the time an enable takes effect until its disable or disposal has taken effect and its attachment has ended. An enable or reload is rejected while another enabled or quarantined instance holds the same key.

A failed load leaves the instance failed. The graph retries it when the provider generations it would bind differ from those it failed against, and an explicit enable or reload retries it at once.

A cleanup failure quarantines the instance. A quarantined instance holds no attachment, never runs another inverse, and does not hold back its providers or parent. It keeps its contract reservations for the life of the runtime, and enabling or reloading it is rejected. Resource authority stays revoked once an inverse has failed, even if an outer inverse catches the error.

A failure inside a drain is attributed to its instance, recorded as its diagnostic, logged, and delivered to every `lunette.onError` listener. An error from an operation a caller invoked, such as `effect:dispose()`, goes to that caller. A blocked instance reports why: a missing or disabled provider is a waiting condition logged at information level, and a schema mismatch, a dependency cycle, or a quarantined provider is an error.

Source reload retires the contract epoch ([Reload](lua-api.md#reload)), so contracts can be declared again in the new epoch. Installing a definition from a retired epoch is rejected. Instance reload unloads and loads one instance within its runtime. Hard restart replaces the Lua state, the attachment, and the epoch.

## GPU ownership

LÖVR creates the `VkInstance`, `VkPhysicalDevice`, `VkDevice`, and queues. The compositor thread uses that device only to create images from imported dmabufs. It submits no work to any queue. Copies into composition-layer backing run inside LÖVR's command stream on the main thread, and the OpenVR backend hands output images to the runtime under LÖVR's queue guard. See [Rendering](rendering.md).

## Crate layering

```
lunette                           binaries; main(), Lua injection, plugin runtime, frame orchestration
lunette-compositor                smithay; no LÖVR dependency, no GPU use beyond image creation
lunette-capture                   wlx-capture and HidProvider wrappers, and the host clipboard client
lunette-lovr                      cmake build and FFI surface for LÖVR
lunette-luau                      the Luau type language; mlua support behind a feature
lunette-generate-definitions      generates the Luau definitions, declarations, and .luaurc files
```

`lunette-compositor` must not depend on `lunette-lovr`. This keeps logic-headless testing possible ([Build and development](build-and-development.md#testing)) and keeps the graphics module out of window management. `lunette-capture` depends on `lunette-compositor` for the host clipboard seam, `HostSelectionSource`, and the compositor does not depend on it.

## Survival across lifecycle events

| Event | Wayland clients | GPU and XR session | Lua state | Plugin attachment |
|---|---|---|---|---|
| Source reload (`lunette.reload()`) | survive | survives | retained; modules run again | runtimes close; a new contract epoch starts |
| Instance reload | survive | survives | retained | one instance unloads and loads again |
| Hard restart (`lovr.event.restart()`) | survive | torn down and rebuilt | replaced | replaced with the Lua state |
| Process exit or crash | terminated | destroyed | destroyed | destroyed |

After either reload or restart, `lunette.windows()` enumerates the same clients again.

[Reload](lua-api.md#reload) states the order of a source reload. Hard restart closes the plugin runtimes, clears subscribers, flushes the final frame, stops native users of the Lua state, marks the mlua state closed, and calls LÖVR's external close path.

## Decisions

LÖVR owns every headset session through an internal backend. Routing XR through a separate Rust runtime was rejected because it would split session ownership and make the engine's input and rendering API inaccurate. The OpenVR backend is a larger patch than the fork otherwise accepts, and it leaves OpenXR behaviour unchanged. Backend selection is fixed before GPU creation ([LÖVR integration](lovr-integration.md#backend-selection)).

The compositor runs off the frame thread, and Lua sees snapshots in exchange. WayVR's main-thread tick works for WayVR; an overlay's value depends on not disturbing the application underneath.

Service types are local contracts, and the runtime validates the graph. A statically inferred type for the whole provider graph was rejected because the Luau subtype normaliser exceeded its 20,000-step budget on an empty initializer, and changing compiler limits was rejected.

Plugin callbacks are synchronous. Cordis lets an activation suspend in an asynchronous step and diverts it when its target changes. Here a cancelled activation is aborted at the next boundary the attachment controls: the next `effect`, `child`, or publication. This removes the in-flight transition state that asynchronous callbacks need.

Reservations are held by enablement and keyed by name and schema. Reserving at installation was rejected because an installed but disabled instance would block a replacement. Releasing whenever an attachment ends was rejected because a second provider could take the contract from an enabled instance that is waiting for a dependency. Keying by name alone was rejected because it prevents `x@1` and `x@2` from coexisting, which a bridge provider needs.

Children drain before parents, and dependents before providers. A child therefore never observes a parent that has begun cleanup, and the graph can retire a child with the activation that installed it without a compensating effect.

A quarantined instance holds no attachment. Keeping the attachment would keep the instance counted as a dependent and child, so its providers and parent would accept a disable that is never carried out. The reservations stay because the state behind a failed inverse is unknown. Cordis's reference harness logs a failed inverse and continues; quarantine is stricter because lunette's effects hold native resources.

A failed load is retried when its bindings change and never against the same bindings. Retrying against the same bindings repeats the failure on every drain, and never retrying leaves a consumer failed after its provider is replaced.

A provider generation derives from its load activation. A separate publication counter would duplicate freshness state.

An effect has one acquisition and one inverse. Cordis's harness accepts a generator that registers each yielded disposer. Here a multi-step acquisition registers each step as its own effect, and an effect created during another's acquisition is registered at once as a sibling, so earlier steps stay registered when a later step raises. Generators would only restate a sequence of effects, and Luau coroutines cannot yield across the native boundary.

A contract is matched by exact name and schema, without compatible ranges (issue #32). A range needs a compatibility relation the runtime cannot check, because the interface behind a schema number is a Luau type the runtime does not see. A provider that serves two schemas provides both contracts.

The shipped composition binds LÖVR's callbacks outside the plugin graph and dispatches them inside it. `frame.install` assigns the callbacks once, before the runtime exists, because `lovr.load` creates the runtime and `lovr.quit` closes it. Assigning them from the frame provider's own effect and restoring the previous values on unload was rejected: the restore is correct only when assigners unload in reverse order, which instance reload and a second runtime do not guarantee.

## Known gaps

Source reload is not transactional. It closes the runtimes and clears callbacks and modules before it runs the new `main.luau`, so a configuration that fails to evaluate leaves whatever it installed before it raised. Cordis imports replacement modules before disposing the old fibers and restores them when an import fails. Doing the same here requires evaluating a configuration without activating it, and two contract epochs live at once. [Reload](lua-api.md#reload) describes the failure path.

## Deliberately left open

Realms are open. Cordis's `ctx.isolate` scopes a key to a subtree, so two providers of one key can coexist. lunette has one realm per runtime graph. A separate runtime graph is the coarse substitute, and a broker provider ([Confinement](lua-api.md#confinement)) substitutes for coexisting implementations. No shipped plugin needs a subtree-scoped service.

Configuration reconciliation is open. A running activation keeps the configuration it was loaded with. `instance:requestReload(config)` and the next drain unload and load the instance, and a changed configuration file is applied by source reload. Applying a configuration in place needs a stable instance identity across reloads and a configuration that `main.luau` declares rather than constructs.

Worker-state access is open. Read-only snapshot access from `lovr.thread` and `lovr.task` states may be useful later. The [ownership rules](#ownership-rules) do not preclude it.
