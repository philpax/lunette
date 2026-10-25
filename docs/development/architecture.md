# Architecture

## Process and thread structure

Rust owns the process and dynamically links LÖVR. Native session resources precede graphics initialization and outlive the Lua state.

| Thread | Ownership |
|---|---|
| Main | Luau state, LÖVR, XR session, and GPU submission |
| Compositor | Wayland display, clients, surfaces, seats, and child processes |
| Control | Local control socket; evaluation runs on the main thread between frames |

Capture has separate worker threads. Bounded channels connect the compositor and frame loop. Compositor dispatch stays off the frame thread because client traffic, spawning, and stalled writes must not consume the overlay's frame budget.

## The snapshot model

Lua reads one per-frame snapshot. Mutations are asynchronous requests; a resize is a configure request, and a client can delay or reject it. Completion is observed in later snapshots or events. [Handle guarantees](native/lua-api.md#handles) specify binding identity and lifetime.

## Ownership rules

The compositor owns authoritative native state outside Lua. The plugin attachment holds the Lua values needed by the current state's runtimes. Each operation carries an activation identity; expired activations have no resource authority. Reload and restart close runtimes before clearing modules or closing the state. The native API and plugin attachment exist only in the main Lua state.

The main state's standard library is frozen before configuration code runs, and its builtin global names cannot be rebound. Luau's builtin fast paths assume unchanged builtins and are enabled only in a safe environment, so this protection is what lets them run. Imports are still looked up when they run, because the host and tests rebind tables such as `lovr.graphics` after code loads; [`environment.rs`](../../crates/lunette/src/environment.rs) owns the protected set.

`lunette-compositor` must not depend on `lunette-lovr`. This preserves logic-headless testing. `lunette-capture` implements host integration seams declared by the compositor; the compositor does not depend on capture.

## Plugin runtime

The [facade and ownership specification](../../lua/lunette-plugin/README.md) own author-facing lifecycle rules. The native graph in `crates/lunette/src/plugin/graph/` is a pure lifecycle core. The attachment executes its plans against Lua. Initializers and inverses are synchronous and cannot yield. A bounded drain can stop and resume, including during close.

Contracts match exact name and schema. Service types are checked locally by Luau; the runtime validates wiring and binds services to provider activations. Whole-graph type inference exceeded Luau's normalization budget, and schema ranges would require a compatibility relation unavailable at runtime.

Services publish together only after successful initialization and validation of required providers. Cancellation or failure publishes nothing. Children unload before parents, and dependents before providers. A failed load retries when its provider bindings change or on explicit request, not on every drain.

An enabled instance reserves its provided contracts while waiting for dependencies. Reserving at installation would block disabled replacements; releasing on every attachment end would let another provider displace a waiting instance. Cleanup failure revokes authority and quarantines the instance. Its attachment ends, but its reservations remain because the resource state is unknown. It never runs an inverse again.

## GPU ownership

LÖVR creates the Vulkan instance, device, and queues. The compositor creates imported images on that device but submits no queue work. Copies and conversions run in LÖVR's main-thread command stream. OpenVR texture handoff uses the graphics queue guard. [Rendering](native/rendering.md) specifies synchronization and image lifetime.

## Survival across lifecycle events

| Event | Clients | Lua and graphics | Plugin resources |
|---|---|---|---|
| Source reload | Survive | State and graphics survive; modules run again | Runtimes close; contract epoch changes; named seats can transfer |
| Instance reload | Survive | Unchanged | One activation is replaced |
| Hard restart | Survive | State, graphics, and XR session are replaced | Runtimes close; plugin seats are replaced |
| Process exit | End | Destroyed | Destroyed |

The default seat survives restart with the compositor. [Source reload](native/lua-api.md#reload), [seat handover](native/input.md#seat-lifetime), and [device restart](native/lovr-integration.md#restart-semantics) specify teardown ordering.

## Known gaps

Source reload is not transactional. Evaluation starts after old runtimes and modules are cleared; a failing replacement leaves what it installed before raising. Rollback requires evaluating without activation and supporting overlapping contract epochs.

## Deliberately left open

Subtree-scoped providers and in-place configuration reconciliation are not implemented. Independent runtime graphs provide coarse isolation. A configuration change replaces an activation. Read-only native snapshots for worker Lua states remain open.
