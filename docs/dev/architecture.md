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

The compositor and session own native state independently of the Lua state. Handles are recreated when a hard restart creates a new Lua state, while Wayland clients remain owned by the compositor.

The plugin attachment is a deliberate exception to the rule that Rust holds no Lua values. It stores plugin definitions, callbacks, service values, and cleanup effects in the current Lua state. Each attachment context carries a runtime, instance, and activation identity. The host rejects operations from an expired activation. Source reload closes every plugin runtime before it clears the user's modules. Terminal cleanup also retires the runtimes before the final frame and external Lua-state close. This ordering limits retained references; it does not establish leak-free external close behavior.

The `lunette` API and plugin attachment are available only in the main Lua state. `lovr.thread` and `lovr.task` create additional Lua states, which do not receive them. Window management from a worker thread is not a required capability, and supporting it would require substantial synchronisation. If a use case arises, the likely form is read-only snapshot access in worker states. This remains open.

## Plugin runtime

A Lua state owns one plugin attachment and contract epoch. The attachment can create independent runtime graphs. Definitions and contract tokens are shared within the state; instances, services, effects, and configuration values belong to one runtime graph.

A contract has an authority-qualified name and a positive schema number. A frozen capability wrapper binds exactly once to the native token for that identity. Declarations retain the exact immutable wrapper. The registry shares these tokens and wrappers across runtime graphs in the same Lua state and epoch, and rejects duplicate identities in that epoch. A plugin definition declares its exact required and provided capability records and a configuration type. `Context:require<T>(capability)` returns the capability's service type. The init-only `Publisher:provide<T>(capability, value)` stages a service for publication.

Luau checks each declared service shape, method signature, and configuration type in the source modules. The checker does not prove that a complete runtime graph is wired correctly. Runtime validation rejects undeclared capability access, absent providers, duplicate or extra provisions, nil values, and publication after the initializer expires. The native graph matches exact contract name and schema and binds a consumer to a specific provider generation. The adapter keeps erased casts private.

Initialization and cleanup callbacks run synchronously and do not yield. Services remain private until initialization succeeds and the graph confirms that every required provider generation is still active. The graph then publishes the complete staged service record atomically. A failed initializer publishes nothing and runs registered cleanup effects in reverse order. A cleanup failure quarantines the instance's contract reservations for the rest of that runtime; shutdown does not retry an inverse that already failed.

Source reload closes plugin runtimes, clears subscriptions and user modules, retires the old contract epoch, and runs the configuration again in the same Lua state. Contract names and schemas may be declared again in the new epoch. Runtime-local instance reload is a separate operation. It unloads and loads one instance while retaining its runtime and state epoch. Hard restart replaces the Lua state and creates a new attachment and epoch.

## Shipped desktop composition

`etc/xdg/lunette/main.lua` selects the built-in panel, interaction, laser, keyboard, tag, rules, adoption, arc-layout, and error-display providers. Configuration-local modules under `etc/xdg/lunette/desktop/` consume those services and own callback registration. The configuration creates one plugin runtime graph. Its callback registry invokes handlers only while their plugin contexts remain active.

The desktop policy owns one persistence state outside the policy plugin activation. Rules contribute placement properties at precedence 100. The persisted arrangement contributes pose, size, and tags at 200. The native per-window property source contributes hand-placed pose at 300. Adoption registers the native property source. Higher precedence wins for a property, so saved arrangement state overrides configured rules and native per-window state overrides saved state.

The desktop integration tests exercise ten production source reloads, isolated keyboard and error-display outages, policy recovery, persistence across policy outages, and quit-save failures. The tests use the real provider definitions and configuration-local consumers with fixture callbacks and native-resource seams. They do not establish that the shipped configuration boots on XR hardware or through a GPU-backed session.

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

| Event | Wayland clients | GPU and XR session | Lua state | Plugin attachment |
|---|---|---|---|---|
| Source reload (`lunette.reload()`) | survive | survives | retained; configuration modules are reloaded | runtimes close; a new contract epoch starts |
| Instance reload | survive | survives | retained | one instance unloads and initializes again |
| Hard restart (`lunette.restart()`) | survive | torn down and rebuilt | replaced | replaced with the Lua state |
| Process exit or crash | terminated with the process | destroyed | destroyed | destroyed |

The compositor owns clients outside the Lua state, so source reload and hard restart leave them connected to the same Wayland socket. Windows can be enumerated again through `lunette.windows()` after either operation.

Source reload does not discard the Lua state or its globals. It closes plugin runtimes, clears subscriber handles and configuration callbacks, drops user and standard-library modules from `package.loaded`, retires contract tokens by advancing the epoch, then runs `main.lua` and `lovr.load`. It does not invoke `mullion.teardown.run()`. Lua modules that need source-reload cleanup must not assume the hook registry is called by the host.

Hard restart does not preserve plugin runtimes or Lua handles. The host shuts down plugin runtimes and clears subscribers, flushes the final frame, quiesces or stops native users of the Lua state, marks the mlua state closed, and then calls LÖVR's external close path. This ordering does not settle every allocator-bookkeeping concern around external close.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

OpenXR only; OpenVR never. SteamVR does not implement `XR_EXTX_overlay`. Supporting it would require a second full backend, which would require routing XR outside LÖVR, which would make `lovr.headset` inaccurate. The architecture depends on LÖVR owning the session.

Compositor off the frame thread, at the cost of Lua seeing snapshots rather than live state. WayVR ticks on the main thread and this works for WayVR; lunette does not follow that arrangement because an overlay's value depends on not disturbing the application underneath.

Plugin service types are local contracts, and runtime declarations own graph validation. A recursive statically inferred whole-graph type was rejected because the Luau subtype normalizer exceeded its 20,000-step budget on an empty initializer. No compiler flag or limit change was made. Local service and configuration checking remains useful without making graph wiring a compile-time guarantee.

## Deliberately left open

Questions this design does not answer yet.

`lovr.thread` and `lovr.task` access. The lunette API is main-state only. There may eventually be a use for read-only snapshot access from worker states. The ownership rules in [the ownership rules](#ownership-rules) do not preclude it, but nothing is designed for it yet.
