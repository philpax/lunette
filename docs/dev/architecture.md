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

Luau checks each declared service shape, method signature, and configuration type in the source modules. The checker does not prove that a complete runtime graph is wired correctly. Runtime validation rejects undeclared capability access, absent providers, duplicate or extra provisions, nil values, and publication after the initializer expires. The native graph matches exact contract name and schema and binds a consumer to a specific provider generation. The adapter keeps erased casts private. It publishes each provided value as a frozen view that raises once the provider's activation has ended, so a service reference a consumer keeps does not reach a torn-down provider; [Plugin authoring](lua-api.md#services) states the view's behaviour and the reason its liveness is the provider's.

Initialization and cleanup callbacks run synchronously and do not yield. Services remain private until initialization succeeds and the graph confirms that every required provider generation is still active and will not unload. The graph then publishes the complete staged service record atomically. A failed or cancelled initializer publishes nothing and runs registered cleanup effects in reverse order. A child installed during an activation belongs to that activation and is retired when it ends, including when the load fails or is cancelled. Retirement is permanent: a disposed instance cannot be enabled again, and a retired parent accepts no children.

The native graph lives in `crates/lunette/src/plugin/graph/` and is a pure functional core: it holds lifecycle state, accepts intents, plans one load or unload at a time, and records diagnostics. The attachment in `crates/lunette/src/plugin/attachment/` performs those actions against Lua. An intent changes graph state immediately and returns the graph's rejection to the caller, including from inside a plugin callback. Planning is derived from state, so there is no intent queue: a request made during a drain is seen by that drain, and work one drain does not reach is found by the next. A drain stops after a number of actions proportional to the number of installed instances and raises an error that names the budget; the remaining work stays in the graph. A disable followed by an enable restarts a live activation instead of cancelling out.

An instance reserves the contracts it provides from the moment an enable takes effect until a disable or disposal has taken effect and its attachment has ended. Installation reserves nothing. Reservations are keyed by contract name and schema. An enable or reload is rejected when another enabled instance, or a quarantined one, provides the same key.

A failed load leaves the instance failed. The graph retries it when the provider generations it would be bound to differ from the ones it failed against, and an explicit enable or reload retries it at once. It is never retried against the same bindings.

A cleanup failure quarantines the instance. A failed rollback quarantines it when the load ends. A failed explicit disposal quarantines it when its attachment next ends; until then an active instance keeps serving, and its remaining inverses run in the usual order when it unloads. A quarantined instance holds no attachment and never runs another inverse, so it does not hold back its providers or its parent. It keeps its contract reservations for the rest of the runtime, and an enable or reload of it is rejected. A consumer whose provider is quarantined, or a provider whose contract a quarantined instance still holds, reports a diagnostic that names the quarantined instance.

A failure inside a drain, such as an initializer or inverse that raises, is attributed to its instance. It is recorded as the instance's diagnostic and reported through the path a configuration callback's error takes: it is logged and every `lunette.onError` listener is notified. An error raised by an operation a caller invoked, such as `effect:dispose()`, goes to that caller instead. A blocked instance reports why: a missing or disabled provider is a waiting condition and is logged at information level, while a schema mismatch, a dependency cycle, or a quarantined provider is reported as an error. Shutdown returns its own cleanup failures to the host, which logs them; failures reported earlier are not repeated.

Source reload closes plugin runtimes, clears subscriptions and user modules, retires the old contract epoch, and runs the configuration again in the same Lua state. Contract names and schemas may be declared again in the new epoch. A definition from a retired epoch is rejected when it is installed, and a declaration that holds a capability from a retired epoch is rejected as retired when it is defined. The attachment replaces the contract registry at each retirement, and it remembers the retired capability wrappers in a weak-keyed table so the rejection names the cause without keeping the old wrappers alive. Runtime-local instance reload is a separate operation. It unloads and loads one instance while retaining its runtime and state epoch. Hard restart replaces the Lua state and creates a new attachment and epoch.

## Shipped desktop composition

`etc/xdg/lunette/main.lua` binds the LÖVR callbacks with `frame.install` from `@lunette-plugins/frame`, and from `lovr.load` creates one plugin runtime graph that selects the built-in frame, surfaces, panel, interaction, laser, keyboard, tag, rules, adoption, arc-layout, and error-display providers. Configuration-local modules under `etc/xdg/lunette/desktop/` consume those services and take no configuration. The installed callbacks reach the loaded frame activation, which invokes a handler only while its owner is live, in phase order, and runs each handler under its own protected call: an error one handler raises is reported through `lunette.reportError`, the path a raising callback takes, and the handlers after it still run. `lovr.quit` runs the quit handlers and then closes the runtime. [Frame and surfaces](lua-api.md#frame-and-surfaces) states the contracts.

Each consumer requires only the contracts it uses, so an outage removes only what depends on the missing provider. `desktop/base.lua` mirrors monitors, updates and draws panels, and offers them as surfaces; it requires frame, surfaces, and panels. `desktop/pointing.lua` attaches the two lasers, updates them against every offered surface, and draws them; it requires frame, surfaces, and the laser contract, so a laser or interaction outage stops pointing and leaves panels updating and drawing. `desktop/input.lua` consumes the reload key as a binding and delivers other keys and text to the focused seat through interaction, `desktop/keyboard.lua` offers and draws the wrist button and virtual keyboard through the keyboard contract, `desktop/errors.lua` draws the error display as an overlay, and `desktop/policy.lua` places windows and saves at quit through a quit handler. The ray intersection the wrist button and keyboard pick with is `@lunette-contracts/quad`, and the pose property adoption reads is in `@lunette-contracts/vocabulary`, so neither the keyboard nor adoption requires a provider for a shared constant or helper.

The desktop policy owns one persistence state outside the policy plugin activation, and its own workspace tag. Rules contribute placement properties at precedence 100. The persisted arrangement contributes pose, size, and tags at 200. The native per-window property source contributes hand-placed pose at 300. Adoption registers the native property source. Higher precedence wins for a property, so saved arrangement state overrides configured rules and native per-window state overrides saved state. The persistence binding saves when a grab drops a panel, and the policy saves again at quit.

The desktop integration tests exercise ten production source reloads requested by F5 from inside `lovr.keypressed`, with every subscription required to have ended when the plugin runtimes shut down. They cover isolated keyboard, error-display, interaction, laser, and tags outages, an interaction outage in the middle of a drag, policy recovery, persistence across policy outages, monitor hotplug and fast replug, windows that close and reopen, substitute panels, rules, and error-display providers, raising frame handlers and surface offers, frame phase order and key consumption, a frame provider outage, a plugin without configuration that draws and offers a surface, and quit-save failures. The tests use the real provider definitions and configuration-local consumers with fixture callbacks and native-resource seams. They do not establish that the shipped configuration boots on XR hardware or through a GPU-backed session.

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

Source reload does not discard the Lua state or its globals. It closes plugin runtimes, clears subscriber handles and configuration callbacks, drops user and standard-library modules from `package.loaded`, retires contract tokens by advancing the epoch, then runs `main.lua` and `lovr.load`. Plugin effects are the only cleanup it runs. Lua code outside a plugin that holds native resources keeps them across the reload unless something else releases them.

Hard restart does not preserve plugin runtimes or Lua handles. The host shuts down plugin runtimes and clears subscribers, flushes the final frame, quiesces or stops native users of the Lua state, marks the mlua state closed, and then calls LÖVR's external close path. This ordering does not settle every allocator-bookkeeping concern around external close.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

OpenXR only; OpenVR never. SteamVR does not implement `XR_EXTX_overlay`. Supporting it would require a second full backend, which would require routing XR outside LÖVR, which would make `lovr.headset` inaccurate. The architecture depends on LÖVR owning the session.

Compositor off the frame thread, at the cost of Lua seeing snapshots rather than live state. WayVR ticks on the main thread and this works for WayVR; lunette does not follow that arrangement because an overlay's value depends on not disturbing the application underneath.

Plugin service types are local contracts, and runtime declarations own graph validation. A recursive statically inferred whole-graph type was rejected because the Luau subtype normalizer exceeded its 20,000-step budget on an empty initializer. No compiler flag or limit change was made. Local service and configuration checking remains useful without making graph wiring a compile-time guarantee.

Plugin callbacks are synchronous and must not yield. Cordis lets an activation suspend in an asynchronous step and diverts it when its target changes. Here an activation that is cancelled while its initializer or an acquisition runs is aborted at the next boundary the attachment controls: the next `effect`, `child`, or publication. This is Cordis's divert reduced to a synchronous abort, and it removes the in-flight transition state that asynchronous callbacks require. A Lua coroutine yield across the native boundary is an error.

Contract reservations are held by enablement and keyed by name and schema. Reserving at installation was rejected because an installed but disabled instance would block a working replacement. Releasing whenever an attachment ends was rejected because a second provider could then take a contract from an instance that is still enabled and only waiting for a dependency, after which the original loops between loading and rollback. Holding the reservation from enable until the disable or disposal has taken effect matches the requirement that two active plugins cannot provide the same key, and rejecting the second enable reports the conflict to the caller that caused it. Keying by name alone was rejected because it prevented `x@1` and `x@2` from coexisting, which a staged schema migration and a bridge provider that serves both need.

Children drain before parents, and dependents drain before providers, before an unload begins. Cordis only requires that a parent's effects, including its children, are reverted before it is inactive. The stronger ordering means a child never observes a parent that has begun cleanup, and the graph can retire a child with the activation that installed it, including an activation that failed or was cancelled, without a separate compensating effect.

A quarantined instance holds no attachment. The rejected alternative keeps the attachment and runs the remaining inverses at shutdown, so the quarantined consumer still counts as a dependent and a child, and its providers and parent accept a disable or reload that is never carried out. A quarantined instance never runs another inverse, so it no longer needs its providers or parent. Running the remaining inverses when its attachment ends, in the ordinary order, keeps every inverse attempted exactly once without pinning anything. What stays quarantined is the instance's own contract reservations, because the state behind a failed inverse is unknown and a replacement provider could conflict with it. The Cordis reference harness logs a failed inverse and continues; quarantine is a stricter choice made because lunette's effects hold native resources.

A failed load is retried when its environment changes and never against the same one. Cordis's lifecycle does not retry a failed fiber against an unchanged target, while its reference harness retries on every notification. Retrying against the same bindings would repeat the same failure on every drain; never retrying would leave a consumer failed after the provider it failed against has been replaced. The environment is the exact bindings, including provider generations, so a provider reload is a change and an unrelated graph change is not.

An effect has one acquisition and one inverse. Cordis's reference harness also accepts a generator from `ctx.effect`, registering each yielded disposer as it is produced, so an effect that fails after its third step rolls back the first two by itself. Here `Context:effect` takes a function that acquires and answers one inverse, and an acquisition that raises registers nothing. A multi-step acquisition that needs partial rollback registers each step as its own effect: an effect created during another's acquisition is registered at once as a sibling, so a later step that raises leaves the earlier steps registered, and they are released when the activation ends or the failed load is rolled back. Generators were not adopted because callbacks are synchronous and do not yield, so a generator would only restate a sequence of effects, and because Luau coroutines cannot yield across the native boundary that registers each step.

A contract is matched by exact name and schema, and there are no compatible ranges. Issue #32 specifies that a consumer requiring a contract at schema 2 does not activate against a provider of schema 1 or 3. Cordis links by key identity alone and, in section 6.6, leaves interface drift to peer-dependency version ranges enforced by a package manager. A range would need a compatibility relation between schemas that the runtime cannot check, since a schema is a number and the interface behind it is a Luau type the runtime does not see. A provider that serves two schemas provides both contracts, and a bridge provider adapts one schema to another; reservations are keyed by name and schema so that either can coexist with the original. Cross-repository version resolution and authority ownership belong to plugin packaging, #39.

The shipped composition binds LÖVR's callbacks outside the plugin graph and dispatches them inside it. `frame.install` assigns the callbacks once, before the runtime exists, because `lovr.load` creates the runtime and `lovr.quit` closes it, and neither can belong to a plugin of that runtime. Dispatch belongs to the frame provider, so plugins register frame work as owner-scoped effects and an outage or reload of one plugin removes only its handlers. Assigning the callbacks from the provider's own effect and restoring the previous values on unload was rejected: the restore is correct only when assigners unload in reverse order, which instance reload and a second runtime do not guarantee. [The Lua API](lua-api.md#frame-dispatch-and-the-surface-list-are-contracts) records the rest of that decision.

## Known gaps

Named, not solved.

Source reload is not transactional. It shuts down the plugin runtimes, clears callbacks and modules, and only then runs the new `main.lua`, so a configuration that fails to evaluate leaves the session with whatever it installed before it raised and not the previous configuration. Cordis's hot module replacement imports the replacement modules before it disposes the old fibers, and restores the module caches and rebuilds the previous fibers when an import fails, so it never leaves a half-reloaded state. Doing the same here requires evaluating the new configuration without activating it: `main.lua` assigns callbacks and creates runtimes as it runs, so it would have to return its composition rather than perform it, or the host would have to snapshot `package.loaded`, the configuration callbacks, and the native subscriptions and restore them and the previous runtimes on failure. The new configuration also declares its contracts in a new epoch while the old runtimes still hold theirs, so two epochs would have to be live at once. The reload failure path is described in [the Lua API](lua-api.md#reload).

## Deliberately left open

Questions this design does not answer yet.

Realms, isolation, and interception. Cordis's `ctx.isolate` scopes a key to a realm, so two providers of one key can coexist in different subtrees and a subtree can be given a private instance of a service, and `ctx.intercept` attaches per-subtree configuration that a service reads when a consumer accesses it. lunette has one realm per runtime graph: a contract name and schema has at most one active provider in a graph. A separate runtime graph is the coarse substitute for a realm, and a broker provider (see [Confinement](lua-api.md#confinement)) is the substitute for several coexisting implementations. Neither is built because no shipped plugin needs a subtree-scoped service, and realms change what a declaration resolves to, which every reservation and diagnostic rule above would have to be restated for.

Declarative configuration reconciliation. Cordis's loader keeps a configuration tree in step with running fibers and applies the least disruptive change per field: a new configuration payload is handed to the running component, which may apply it without reloading. lunette has no in-place configuration update. A running activation keeps the configuration it was loaded with. `instance:reload(config)` replaces the configuration by unloading and loading the instance, which cascades to its dependents, and a changed configuration file is applied by a source reload, which rebuilds every runtime. Reconciliation would need a stable identity for each instance across source reloads and a configuration that `main.lua` declares rather than constructs; both are open alongside the transactional reload above.

`lovr.thread` and `lovr.task` access. The lunette API is main-state only. There may eventually be a use for read-only snapshot access from worker states. The ownership rules in [the ownership rules](#ownership-rules) do not preclude it, but nothing is designed for it yet.
