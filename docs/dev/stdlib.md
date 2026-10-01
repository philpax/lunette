# Standard library

`mullion` is an optional Lua library installed below `$PREFIX/share/lunette/lua/`. Its modules are value helpers and policy that no provider owns. They use the public `lunette` API and the plugin contracts, and can be replaced or omitted. `@lunette-plugin`, `@lunette-contracts`, and `@lunette-plugins` provide the typed plugin facade, neutral service contracts, and built-in plugin implementations. The shipped configuration selects those providers and defines desktop-specific consumers under `etc/xdg/lunette/desktop/`. Their lifecycle and type boundary are specified in [The Lua API](lua-api.md#plugin-authoring) and [Architecture](architecture.md#plugin-runtime).

## Module roots

The source tree is `lua/`. A running session mounts file-backed roots through LÖVR's virtual filesystem. The checker resolves aliases from generated `.luaurc` files. `@lunette` is registered natively through `package.preload`; the checker reads its generated declaration from `lua/lunette/init.luau`.

The plugin facade is `lua/lunette-plugin/`. Shared contracts and vocabulary are in `lua/lunette-contracts/`. Built-in providers are in `lua/lunette-plugins/`. `lua/mullion/` contains optional helper and policy modules. `lua/spec/` is a development-only root and is not installed. [Build and development](build-and-development.md#module-roots) records the source of truth and install behavior.

The root module `@mullion` re-exports nothing. Each module is required by its own path, such as `require '@mullion/pose'` or `require '@mullion/persist'`. A configuration can use `lunette` without loading `mullion` or the built-in providers.

| Module | Responsibility |
|---|---|
| `mullion.persist`, `mullion.persist.arrangement`, `mullion.persist.slots`, and `mullion.persist.format` | Configuration-owned arrangement state, capture and restore, the saved slot each live window holds, file loading and saving, and the versioned file representation. |
| `mullion.pose` and `mullion.keycodes` | Pose encoding and the physical keyboard description, shared by built-in providers and the shipped configuration. |
| `mullion.scale` and `mullion.pacing` | Scale selection with hysteresis and per-window frame-pacing choice. No provider or shipped consumer uses them yet. |

The default configuration uses `mullion.persist` for arrangement state and the `mullion.pose` and `mullion.keycodes` helpers through the policy and provider modules. Panels, interaction, lasers, the virtual keyboard, tags, rules, adoption, arc layout, and error display are built-in providers under `@lunette-plugins`, not `mullion` modules; [Decisions](#decisions) records why their earlier `mullion` implementations were removed.

## Contracts and providers

A neutral contract module declares a service shape and exports a capability. The capability pairs a Luau type with an authority-qualified contract name and schema number. Vocabulary that is shared by several contracts belongs in a neutral contract module so service types do not need to import a provider implementation.

A plugin definition declares its name, its required and provided capabilities, and its initializer, whose configuration parameter gives the definition its configuration type. Its context reads required services with `Context:require<T>(capability)`. Its initializer stages provided services with `Publisher:provide<T>(capability, value)`. The native graph validates runtime wiring and publishes all provided values as one provider generation after initialization succeeds. See [Plugin authoring](lua-api.md#plugin-authoring) for the type boundary and runtime checks.

A provider's service methods carry no liveness guard of their own: consumers reach them through the facade's service view, which raises once the provider's activation has ended. Objects a method returns, such as panels, pointers, lasers, keyboards, and tags, outlive the call and check their own state. A provider whose owner-scoped method needs one of its own dependencies registers that work under its own context, inside the effect it places on the caller's owner, rather than forwarding the caller's owner; the adoption provider's `install` registers its rules source this way. A provider subscribes to native events for its own activation through `Context:on`. The adoption provider's `start` subscribes inside the effect it registers on the caller's owner instead, because that subscription belongs to the caller.

A resource a consumer asks a provider for, such as a pointer, a laser and its seat, a keyboard, a focus grant, a tag membership, or a selection override, is released by an inverse registered on the consumer's owner, not on the provider's context. A release that fails while the owner unloads is the owner's failure and quarantines the owner; the provider keeps serving its other consumers. A resource's `destroy` performs the release on its caller's stack and then disposes the owner's effect, whose inverse has nothing left to do, so a failure raises to the caller that asked for it.

Every change a consumer makes to state it does not own is an effect of its owner. A tag membership is held by the owners that added it, and the panel stays a member while any holder remains; an owner removes only its own hold, and the tag's owner removes every hold. A tag's selection is decided by the most recent live selection override, one per owner, and a tag with none has the selection it was created with. Keyboard focus is held by the pointer that gave it or by the owner of a `setFocus` grant, and a holder that ends withdraws the seat's focus natively and is no longer answered by `focused`, unless a later holder has taken the seat. A laser hand has one owner under `attach`, which raises rather than hand one owner another's laser. A rules source name names one registration, and registering a name already registered raises.

The panels contract announces a panel's arrival and removal to owner-scoped listeners, `onAdded` and `onRemoved`. Removal is announced for every cause: the owner destroying the panel or unloading, the source dying, or the provider unloading. Only the owner that created a panel destroys it. Rules ends a placement when its panel is removed, adoption ends an adoption, the desktop's mirror consumer ends a mirror, and persistence restores a monitor panel as it arrives, all through this contract and none through a provider's private module. A listener that raises is reported through `lunette.reportError` and does not fail the operation that added or removed the panel.

LÖVR's frame and input callbacks reach plugins through the `lunette/frame` contract, and the surfaces a pointer picks from are brokered by `lunette/surfaces`; [Frame and surfaces](lua-api.md#frame-and-surfaces) states both. `@lunette-plugins/frame` exports its definition and `install`, which binds the LÖVR callbacks to it, and `@lunette-plugins/surfaces` is a definition like the other providers. Both providers call each handler and offer through `@lunette-plugins/protected`, which reports an error through `lunette.reportError` and continues; the panels provider calls its listeners the same way.

Constants and helpers that several providers agree on are neutral vocabulary rather than service fields. The per-window pose property is `@lunette-contracts/vocabulary`'s `POSE_PROPERTY`, and ray intersection with a flat quad is `@lunette-contracts/quad`. A provider's tuning and style tables are copied and frozen for each activation, so no consumer can retune another's.

Built-in provider modules exist for adoption, error display, frame dispatch, interaction, keyboard, laser, arc layout, panels, rules, surfaces, and tags. The providers use the typed plugin facade. Some providers share narrow value helpers from `mullion`, including pose encoding and keycode tables. Replacing a provider keeps its capability and declared service shape. A replacement implements the existing interface; the contract is not weakened to accommodate it.

## Default configuration

`etc/xdg/lunette/main.lua` is the shipped configuration and the source of truth for its provider composition. It binds the LÖVR callbacks with `frame.install`, and from `lovr.load` enables the built-in frame, surfaces, panel, interaction, laser, keyboard, tag, rules, adoption, arc-layout, and error-display providers in one runtime graph. It then enables configuration-local consumers for desktop behavior. No consumer takes configuration: each requires the frame and surfaces contracts it uses, as a plugin in a user's configuration would. The configuration keeps a global guard so source reload does not spawn another demonstration terminal.

`etc/xdg/lunette/desktop/policy.lua` owns placement policy and creates a persistence state outside the policy instance's activation. It creates its own workspace tag, restores saved arrangements, configures application rules, and starts adoption. Its persistence binding saves when a grab drops a panel, and the policy saves again at normal quit. The rule sources apply in ascending precedence: configured rules at 100, saved arrangement state at 200, and native per-window properties at 300. A higher-precedence source overrides a lower-precedence value for the same property. Saved state supplies pose, size, and tags; the native source supplies hand-placed pose.

A placement owns each implicit tag it creates. Cleanup at the end of the placement's lifetime removes the memberships it added, its panel, and its newly created tags. Existing tags are borrowed and survive cleanup. Borrowing a newly created tag does not extend the creator's lifetime; tags are not reference-counted, and creator cleanup still removes them.

A persistence state retains its loaded arrangement, the slot each live window holds, and any refusal to overwrite a broken or newer-format file while the policy provider is disabled and re-enabled. A binding belongs to one activation. Its rules source and arrival listener read the arrangement last loaded or saved, so a save reaches the windows and monitors that appear after it. Resolving a window is a query: a window answers the slot it holds, or the lowest slot no live window of its application holds, and only the creation of its panel takes the slot. A window holds its slot until it dies, so a window that closes and reopens takes the slot it left. A monitor panel that appears after the binding, through hotplug or a reload of the mirroring consumer, is restored as it appears. Disposing a binding removes the source and listeners and clears references to the old context and services. A normal quit attempts to save. A returned write failure or a thrown save error is reported by the frame provider, and `lovr.quit` returns `false` so the failure does not veto shutdown.

The desktop consumers each require only the contracts they use. `desktop/base.lua` mirrors monitors, updates and draws panels in the `scene` phase, and offers them as the `desktop/panels` surfaces. `desktop/pointing.lua` attaches the lasers, updates them against every offered surface and draws them in the `pointing` phase, so a laser or interaction outage leaves panels updating and drawing. `desktop/keyboard.lua` offers the wrist button and its keyboard as `desktop/keyboard` and draws them in the `scene` phase after the panels. `desktop/input.lua` consumes the reload key as a `binding` and forwards other keys and text to the focused client as `delivery`. `desktop/errors.lua` draws the error display in the `overlay` phase. The frame provider runs each handler under its own protected call and reports a handler's error through `lunette.reportError`, so one handler's error does not stop the others, including the error display.

The desktop integration tests cover frames and input with ten production source reloads requested by F5, selective keyboard, error-display, interaction, laser, and tags outages, an interaction outage in the middle of a drag, policy recovery, retained arrangement and write-refusal state across policy outages, monitor hotplug and fast replug, windows that close and reopen, substitute panels, rules, and error-display providers, source precedence, raising frame handlers and surface offers, phase order, key and text consumption, frame registrations ending with their owner, duplicate offer names, a frame provider outage, a plugin without configuration drawing and offering a surface in the shipped composition, and quit-save return and exception failures. The tests use the real provider definitions and configuration-local consumers with fixture callback and native-resource seams. They do not establish an actual XR or GPU-backed boot, host-desktop acceptance, or successful installation and execution of a copied configuration.

Safe mode is compiled into the binary and requires `lunette` alone. It does not depend on `mullion` or the provider roots, because a missing or broken installed module tree must not prevent recovery. [The Lua API](lua-api.md#errors) records its behavior.

## Module lifecycle

The host's source reload retains the Lua state. It shuts down plugin runtimes, clears native subscribers and configuration callbacks, drops unprotected modules from `package.loaded`, advances the plugin contract epoch, and runs `main.lua` and `lovr.load` again.

Plugin implementations register cleanup effects with their context or owner. The native runtime runs these effects during disable, instance reload, disposal, and shutdown. An expired activation cannot use its context or publisher. A cleanup failure quarantines the instance: the runtime does not retry an inverse that already failed, runs the instance's remaining inverses when its attachment ends, and never loads it again. A quarantined instance keeps its contract reservations but does not hold back its providers or parent. Cleanup failures during a drain are reported through `lunette.onError`; a failing `effect:dispose()` raises to its caller.

Plugin effects are the only cleanup mechanism. There is no Lua teardown registry: the one `mullion` had was absorbed into the effect layer, as issue #32 specifies. A `mullion` module keeps no module-level state: a persistence state belongs to the caller that creates it, and its bindings are plugin effects. A Lua module outside a plugin that owns native resources releases them through a lifecycle path of its own or tolerates their continued existence; [Known gaps](#known-gaps) records this.

`lua/spec/` mirrors the `mullion` tree with specifications and test support. It is available only in development. The checker includes the ordinary suite modules, while computed spec requires and negative type probes are handled by their dedicated tests. `make check` includes subprocess integration tests that start `lunette` with headless fixtures. It does not run a hardware acceptance session.

## Policy and mechanism

| Concern | Owner | Reason |
|---|---|---|
| Window and monitor handles, sinks, input delivery, outputs, layers, and capture | `lunette` | These operations cross native, compositor, or device boundaries. |
| Panel layout, surface picking, pointer behavior, and frame-rate policy | Lua modules and providers | Configurations can replace policy without changing the native API. |
| Contract identity, exact provider bindings, lifecycle, and resource cleanup | Native plugin runtime | These rules span service providers and must remain consistent within a runtime graph. |
| Service methods and configuration types | Luau contracts and definitions | The checker can validate local source shapes without inferring the complete runtime graph. |

The panels provider adapts native window and monitor pixels to Lua-defined geometry and interaction. A monitor panel remains an in-scene quad because the native layer claim API accepts windows, not monitors. Interaction keeps pointer hover and keyboard focus separate; pointer motion does not implicitly take focus. These boundaries let a configuration change geometry and input policy without changing Wayland protocol behavior.

## Decisions

The standard library stays optional and separate from `lunette`. The native root exposes mechanism, while `mullion` contains replaceable policy and helpers. Keeping distinct roots avoids making a Lua implementation look like native mechanism and lets a configuration omit the library.

Liveness of a service belongs to the facade, not to each provider. Every provider repeated a guard against calls after its activation ended, and a provider that forgot one exposed torn-down state. The facade's service view enforces it once for every provision. Providers keep the checks that guard objects outliving a call, which the view does not reach.

Neutral contracts stay separate from providers. A contract describes a service without importing the module that implements it. This allows plugins to typecheck against the service surface while keeping provider implementations replaceable.

The plugin API uses local capability and configuration types with runtime graph validation. A recursive inferred type for the complete provider graph exceeded Luau's 20,000 subtype-normalization budget even with an empty initializer. Changing compiler flags or limits was rejected. Local static checking remains useful, while declarations and the lifecycle graph validate whole-runtime wiring.

The native adapter contains erased casts. A mapped `Services<R>` and `Provisions<P>` authoring API is not used. `Context:require<T>(capability)` and init-only `Publisher:provide<T>(capability, value)` keep the public typing model direct and place runtime membership checks at the boundary.

### Desktop consumers reach frame and surfaces through contracts

The desktop consumers took the configuration's callback registry through their configuration, so a consumer could not be moved out of the configuration directory or written by a user without copying the registry. They now require `lunette/frame` and `lunette/surfaces` and take no configuration. [The Lua API](lua-api.md#frame-dispatch-and-the-surface-list-are-contracts) records the contracts' shape, the phases, and why the LÖVR callbacks are bound by `frame.install` rather than by the provider. `desktop/base.lua` requires the surfaces contract to offer panels, so a surfaces outage stops panel rendering with it; splitting rendering from offering is left to the split of `desktop/base.lua`.

### Superseded `mullion` modules are removed

The panel, interaction, laser, keyboard, tag, rules, adoption, error, and arc-layout modules of `mullion`, with the signal and teardown modules they were built on, were removed once the built-in providers replaced them. Issue #32 makes the existing standard library the first plugins and absorbs the teardown registry into the effect layer; the providers did both, and the shipped configuration and safe mode used none of the old modules. Keeping them as optional alternatives was rejected. Each was a second implementation of a provider's behaviour with a lifecycle the host no longer runs: their cleanup depended on a teardown registry that source reload and hard restart do not call, so a configuration that used them leaked across every reload, and fixes to a provider would not have reached its legacy twin. The modules that remain are helpers a provider or the persistence binding uses, `mullion.pose`, `mullion.keycodes`, and `mullion.persist`, and the scale and pacing choosers, which no provider replaces. Their history is in the repository.

### Panel lifecycle is announced through the panels contract

Rules ended a placement when its panel died by importing the panels provider's private events module, and a module-global registry there held one cleanup per panel. A replacement panels provider implementing the contract could not end rules placements, and the registry outlived activations. The contract now carries owner-scoped `onAdded` and `onRemoved` listeners, and every consumer that follows a panel's life uses them. A per-panel destroy hook was considered; owner-scoped listeners were chosen because they are effects of their owner, so a listener ends with the plugin that registered it.

A panel is released before its owner's effect is disposed, rather than by that effect's inverse. The runtime withholds an owner's authority while one of its inverses runs, so a removal announced from inside the inverse would reach the owner's own listeners, such as rules ending its placement, as if the owner were gone.

### Consumer resources are released on the consumer's owner

Pointers, lasers, keyboards, and focus grants registered their native release as an effect of the provider's context, inside an effect on the consumer's owner. A release that failed then quarantined the provider for every consumer. The release is now the inverse on the owner, and a direct `destroy` performs it on its caller's stack. The interaction and laser providers' own teardown still releases anything left, which happens only if an owner never unloaded.

### Focus and tag changes belong to the owner that made them

A pointer's keyboard focus outlived the pointer, `setFocus` changed only the Lua answer and not the native seat, and any consumer could change another's tag selection and memberships with no inverse. Focus is now held, and a holder that ends withdraws it natively. Tag memberships are held per owner. A tag's selection is a stack of per-owner overrides in which the most recent live override wins. Reverting an owner's change to the value from before it was rejected: the revert depends on the order owners unload in, and it can restore a value that belonged to an owner that has already gone.

### One registration per name and one laser owner per hand

Registering a rules source under an existing name replaced the registration, ending a resource another owner still held, and `attach` answered another owner's laser for a hand. Both now raise. A consumer that needs a shared resource borrows it from the provider that brokers it rather than taking another owner's.

### Saved slots are held by windows

The persistence source took a slot on every resolve and never freed one, so `rules:resolve` consumed slots, a window that closed and reopened lost its placement, and the source read the arrangement as it was when the binding was made. A slot is now held from the creation of the window's panel until the window dies, resolving is a query, and the source reads the arrangement last saved. Freeing a slot when the panel is removed was rejected: a provider outage removes every panel while the windows remain, and recovery would then give windows each other's slots.

### The arrangement is saved on a drop and at quit

The documentation said the policy saved on panel removal; it saved on a grab's drop and at quit, and that is kept. A panel is removed mostly by outages, reloads, and unloads, when the binding is ending and a save would capture a desktop that is coming apart. A drop is the moment a user has finished arranging a panel.

A grab that the interaction provider's own teardown ends stores the pose property without emitting the drop, because the provider can no longer emit through the panels contract. The native property is never older than the saved arrangement as a result, and it takes precedence over the arrangement, so the newer pose wins. A grab ended while the provider is live, including by the pointer's owner unloading during an interaction outage, emits the drop and stores the pose, and the saved arrangement and the property agree.

## Known gaps

Source reload runs no cleanup for Lua code outside the plugin runtime. A non-plugin module that retains native resources keeps them after the reload unless another owner releases them.

The desktop integration tests do not establish an actual XR or GPU-backed boot, host-desktop acceptance, or successful installed-session execution.

## Deliberately left open

A 2D widget toolkit remains deferred. Larger settings and desktop interfaces fit better in Wayland clients than in a Lua widget framework. Further layout algorithms also remain open; the arc-layout provider is the only layout, and there is no complete 3D layout set.

Deferred follow-up issues include #15, #36, #38, and #39. Their feature scope remains in the issue records. XR hardware and host-desktop acceptance remain human gates, and new desktop features remain outside this specification until their implementation and acceptance criteria are defined.
