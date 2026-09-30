# Architecture

## Process and thread structure

lunette is a single Rust binary that dynamically links LÖVR, which ships beside it as `liblovr.so` ([Build and development](build-and-development.md#building)). Rust owns `main()`.

| Thread | Owns | Communicates with |
|---|---|---|
| Main | The LÖVR Lua state, the OpenXR session, GPU submission, rendering | Compositor thread by channel; control thread by channel |
| Compositor | The Wayland display, smithay state, clients, surfaces, seats, child processes | Main thread by channel; creates images on LÖVR's `VkDevice` |
| Control | The `lunctl` Unix socket | Main thread; submitted chunks run on the Lua thread between frames |

Capture and PipeWire introduce further threads, owned by `wlx-capture`.

Rust hosts LÖVR rather than the reverse because a window manager has lifecycle requirements that precede and outlast graphics initialisation: a Wayland socket, child processes to reap, PipeWire and D-Bus connections, a control socket, and session state that must survive a GPU reinitialisation. Placing that work inside a LÖVR project would subordinate it to LÖVR's command line, configuration file, and startup order.

The cost of this arrangement is that LÖVR access becomes lunette's responsibility. lunette boots the standard LÖVR Lua environment with its own `boot.lua`, not a reduced subset. A LÖVR module that does not work under lunette is a defect.

## Compositor thread placement

WayVR ticks its compositor on the main thread once per frame (`inspiration/wayvr/wayvr/src/backend/wayvr/mod.rs:641`). That arrangement is simpler, is proven in use, and gives Lua a synchronous view of compositor state.

lunette does not use it. An overlay must not disturb the application beneath it. Any slow operation in compositor dispatch, such as a client sending a burst of requests, a D-Bus round trip, a process spawn, or a stalled `wl_display` write, would otherwise consume part of a 90 Hz frame budget. Moving compositor dispatch off the frame thread removes that class of stall.

## The snapshot model

The threading decision determines the most visible property of the Lua API. Lua reads window state as a per-frame snapshot, and every mutation is a request.

- `win.title` is a field on a handle, refreshed at the start of each frame.
- `win:close()` returns nothing. Completion is observed when the window stops appearing.
- `win:resize(w, h)` is a configure request. The client may ignore it, clamp it, or apply it several frames later.

This is a property of Wayland rather than a concession to threading. Wayland is asynchronous, and awesome makes the same arrangement with X11: properties are cached, requests are asynchronous, and results arrive as events. An API that presented synchronous semantics would misrepresent the protocol and would require a breaking change later.

## Handles

A window handle is a persistent Lua object with stable identity, not a new table per frame. The native layer refreshes its fields at the start of each frame.

```lua
lunette.onWindowOpened(function(event)
  local win = event.window
  win.userdata = { spawnedAt = lovr.timer.getTime() }   -- Application state may be attached.
  print(win == lunette.windows()[1])                    -- Identity comparison is valid.
end)
```

Stable identity is required for tags, rules, and signals, each of which must refer to a window observed on an earlier frame.

### Dead handles

When a window closes, Lua may still hold its handle. Reads return the last known values, and `win.dead` becomes `true`. Methods become no-ops that return `false`.

The alternative is to raise an error on access. That is rejected because a window disappearing between frames is a normal event in a compositor, and raising an error for it would allow an ordinary race to terminate the session.

## Ownership rules

The compositor and session own native state independently of the Lua state. Native handles read that state rather than retaining Lua values.

The plugin attachment retains definitions, callbacks, service values, and cleanup effects in its Lua state. Each attachment context carries a runtime, instance, and activation identity. The runtime rejects operations from an expired activation. Closing a runtime disposes its instances and effects.

The `lunette` API and plugin attachment are available only in the main Lua state. `lovr.thread` and `lovr.task` create additional Lua states, which do not receive them. Window management from a worker thread is not a required capability, and supporting it would require substantial synchronisation. If a use case arises, the likely form is read-only snapshot access in worker states. This remains open.

## Plugin runtime

A Lua state owns one plugin attachment and contract epoch. The attachment can create independent runtime graphs. Definitions and contract tokens are shared within the state; instances, services, effects, and configuration values belong to one runtime graph.

A contract has an authority-qualified name and a positive schema number. A frozen capability wrapper binds exactly once to the native token for that identity. Declarations retain the exact immutable wrapper. The registry shares these tokens and wrappers across runtime graphs in the same Lua state and epoch, and rejects duplicate identities in that epoch. A plugin definition declares its exact required and provided capability records and a configuration type. `Context:require<T>(capability)` returns the capability's service type. The init-only `Publisher:provide<T>(capability, value)` stages a service for publication.

Luau checks each declared service shape, method signature, and configuration type in the source modules. The checker does not prove that a complete runtime graph is wired correctly. Runtime validation rejects undeclared capability access, absent providers, duplicate or extra provisions, nil values, and publication after the initializer expires. The native graph matches exact contract name and schema and binds a consumer to a specific provider generation. The adapter keeps erased casts private.

Initialization and cleanup callbacks run synchronously and do not yield. Services remain private until initialization succeeds and the graph confirms that every required provider generation is still active. The graph then publishes the complete staged service record atomically. A failed initializer publishes nothing and runs registered cleanup effects in reverse order. A cleanup failure quarantines the instance's contract reservations for the rest of that runtime; shutdown does not retry an inverse that already failed.

## GPU ownership

LÖVR creates the `VkInstance`, `VkPhysicalDevice`, `VkDevice`, and queues. The compositor thread uses that device for one purpose: creating images from imported dmabufs. It does not submit work to any queue.

That restriction is required by the rest of the design. Copies into composition-layer swapchains are issued inside LÖVR's command stream on the main thread, so ordering against LÖVR's rendering is handled internally by LÖVR, and no other thread submits to its queue. See [Rendering](rendering.md).

## Crate layering

```
lunette            binary; owns main(), Lua injection, frame orchestration
lunette-compositor smithay; no LÖVR dependency, no GPU dependency beyond image creation
lunette-capture    wlx-capture and HidProvider wrappers
lunette-lovr       cmake build, FFI surface, the patch set
```

`lunette-compositor` must not depend on `lunette-lovr`. This keeps logic-headless testing available, as described in [Build and development](build-and-development.md#testing), and prevents the graphics module becoming a dependency of window management.

## Survival across lifecycle events

| Event | Wayland clients | GPU and XR session | Lua state |
|---|---|---|---|
| Soft reload (`lunette.reload()`) | survive | survives | discarded |
| Hard restart (`lunette.restart()`) | survive | torn down and rebuilt | discarded |
| lunette crash | terminated by process group | destroyed | destroyed |

Clients survive both reload paths because they are owned by Rust, outside the Lua state, on a socket that remains open. This property is what makes iterative development of the compositor practical.

Seats, pointers, and outputs are owned by Rust too, so they would survive both paths for the same reason. A reload leaves them, because the Lua state carries on and the handles naming them carry on with it. A restart releases them through the standard library's teardown hooks, because the state closes and every handle in it goes at once, leaving compositor objects that nothing can name and names that the next configuration cannot claim. Windows are the exception on both paths: they belong to their clients, they are re-enumerable through `lunette.windows`, and neither path disturbs them.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

OpenXR only; OpenVR never. SteamVR does not implement `XR_EXTX_overlay`. Supporting it would require a second full backend, which would require routing XR outside LÖVR, which would make `lovr.headset` inaccurate. The architecture depends on LÖVR owning the session.

Compositor off the frame thread, at the cost of Lua seeing snapshots rather than live state. WayVR ticks on the main thread and this works for WayVR; lunette does not follow that arrangement because an overlay's value depends on not disturbing the application underneath.

Plugin service types are local contracts, and runtime declarations own graph validation. A recursive statically inferred whole-graph type was rejected because the Luau subtype normalizer exceeded its 20,000-step budget on an empty initializer. No compiler flag or limit change was made. Local service and configuration checking remains useful without making graph wiring a compile-time guarantee.

## Deliberately left open

Questions this design does not answer yet.

`lovr.thread` and `lovr.task` access. The lunette API is main-state only. There may eventually be a use for read-only snapshot access from worker states. The ownership rules in [the ownership rules](#ownership-rules) do not preclude it, but nothing is designed for it yet.
