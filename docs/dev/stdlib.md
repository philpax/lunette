# Standard library

`mullion` is an optional Lua library installed below `$PREFIX/share/lunette/lua/`. Its policy and presentation modules use the public `lunette` API and can be replaced or omitted. `@lunette-plugin`, `@lunette-contracts`, and `@lunette-plugins` provide the typed plugin facade, neutral service contracts, and built-in plugin implementations. The shipped configuration selects those providers and defines desktop-specific consumers under `etc/xdg/lunette/desktop/`. Their lifecycle and type boundary are specified in [The Lua API](lua-api.md#plugin-authoring) and [Architecture](architecture.md#plugin-runtime).

## Module roots

The source tree is `lua/`. A running session mounts file-backed roots through LÖVR's virtual filesystem. The checker resolves aliases from generated `.luaurc` files. `@lunette` is registered natively through `package.preload`; the checker reads its generated declaration from `lua/lunette/init.luau`.

The plugin facade is `lua/lunette-plugin/`. Shared contracts and vocabulary are in `lua/lunette-contracts/`. Built-in providers are in `lua/lunette-plugins/`. `lua/mullion/` contains optional policy modules. `lua/spec/` is a development-only root and is not installed. [Build and development](build-and-development.md#module-roots) records the source of truth and install behavior.

The root module `@mullion` re-exports nothing. Each module is required by its own path, such as `require '@mullion/panel'` or `require '@mullion/layout/arc'`. A configuration can use `lunette` without loading `mullion` or the built-in providers.

| Module | Responsibility |
|---|---|
| `mullion.signal` | Lua signal connections, emission, and property-change signals. |
| `mullion.teardown` | Explicit Lua cleanup-hook registry. The host does not run it during reload or restart. |
| `mullion.error` and `mullion.error.panel` | Error reporting and its optional in-world display. |
| `mullion.panel` and `mullion.panel.raycast` | Window or monitor panels, ray intersection, and rendering. |
| `mullion.interaction` and `mullion.interaction.types` | Surface picking, pointer interaction, and shared interaction types. |
| `mullion.laser` and `mullion.keyboard` | Lua-managed pointing and virtual keyboard behavior. |
| `mullion.tag`, `mullion.rules`, and `mullion.layout.arc` | Window grouping, placement rules, and arc layout. |
| `mullion.adopt` | Re-enumeration and restoration of windows already open after source reload. |
| `mullion.persist` and `mullion.persist.format` | Configuration-owned arrangement state, file loading and saving, and its versioned file representation. |
| `mullion.pose` and `mullion.keycodes` | Shared value helpers used by built-in providers. |
| `mullion.scale` and `mullion.pacing` | Optional scale selection and frame-pacing policy helpers. |

The default configuration uses `mullion.persist` for arrangement state and shared `mullion.pose` and `mullion.keycodes` helpers through the policy and provider modules. It does not compose the legacy `mullion.panel`, `mullion.interaction`, `mullion.laser`, `mullion.keyboard`, `mullion.tag`, `mullion.rules`, or `mullion.adopt` implementations. Those modules remain in the source tree; their removal is undecided.

## Contracts and providers

A neutral contract module declares a service shape and exports a capability. The capability pairs a Luau type with an authority-qualified contract name and schema number. Vocabulary that is shared by several contracts belongs in a neutral contract module so service types do not need to import a provider implementation.

A plugin definition declares its required and provided capabilities, configuration type, and initializer. Its context reads required services with `Context:require<T>(capability)`. Its initializer stages provided services with `Publisher:provide<T>(capability, value)`. The native graph validates runtime wiring and publishes all provided values as one provider generation after initialization succeeds. See [Plugin authoring](lua-api.md#plugin-authoring) for the type boundary and runtime checks.

Built-in provider modules exist for adoption, error display, interaction, keyboard, laser, arc layout, panels, rules, and tags. The providers use the typed plugin facade. Some providers share narrow value helpers from `mullion`, including pose encoding and keycode tables. They do not use the legacy `mullion` panel, interaction, laser, keyboard, tag, rules, or adoption policy implementations. Replacing a provider keeps its capability and declared service shape. A replacement implements the existing interface; the contract is not weakened to accommodate it.

The legacy `mullion` policy and presentation modules remain in the source tree as optional library modules. The default configuration composes provider definitions from `@lunette-plugins` and desktop consumers from `etc/xdg/lunette/desktop/`. The decision to remove the legacy policy implementations remains open.

## Default configuration

`etc/xdg/lunette/main.lua` is the shipped configuration and the source of truth for its provider composition. It enables the built-in panel, interaction, laser, keyboard, tag, rules, adoption, arc-layout, and error-display providers in one runtime graph. It then enables configuration-local consumers for desktop behavior and callbacks. The configuration keeps a global guard so source reload does not spawn another demonstration terminal.

`etc/xdg/lunette/desktop/policy.lua` owns placement policy and creates a persistence state outside the policy instance's activation. It restores saved arrangements, configures application rules, starts adoption, and saves on panel removal and normal quit. The rule sources apply in ascending precedence: configured rules at 100, saved arrangement state at 200, and native per-window properties at 300. A higher-precedence source overrides a lower-precedence value for the same property. Saved state supplies pose, size, and tags; the native source supplies hand-placed pose.

A placement owns each implicit tag it creates. Cleanup at the end of the placement's lifetime removes the memberships it added, its panel, and its newly created tags. Existing tags are borrowed and survive cleanup. Borrowing a newly created tag does not extend the creator's lifetime; tags are not reference-counted, and creator cleanup still removes them.

A persistence state retains its loaded arrangement and any refusal to overwrite a broken or newer-format file while the policy provider is disabled and re-enabled. A binding belongs to one activation. Disposing it removes the source and callback and clears references to the old context and services. A normal quit attempts to save. A returned write failure or a thrown save error is logged by the callback registry, and the quit callback returns `false` so the failure does not veto shutdown.

The desktop integration tests cover frames and input with ten production source reloads, selective keyboard and error-display outages, policy recovery, retained arrangement and write-refusal state across policy outages, source precedence, and quit-save return and exception failures. The tests use the real provider definitions and configuration-local consumers with fixture callback and native-resource seams. They do not establish an actual XR or GPU-backed boot, host-desktop acceptance, or successful installation and execution of a copied configuration.

Safe mode is compiled into the binary and requires `lunette` alone. It does not depend on `mullion` or the provider roots, because a missing or broken installed module tree must not prevent recovery. [The Lua API](lua-api.md#errors) records its behavior.

## Module lifecycle

The host's source reload retains the Lua state. It shuts down plugin runtimes, clears native subscribers and configuration callbacks, drops unprotected modules from `package.loaded`, advances the plugin contract epoch, and runs `main.lua` and `lovr.load` again. It does not call `mullion.teardown.run()`.

Plugin implementations register cleanup effects with their context or owner. The native runtime runs these effects during disable, instance reload, disposal, and shutdown. An expired activation cannot use its context or publisher. Cleanup failures are reported and quarantined; the runtime does not retry an inverse that already failed.

The Lua teardown registry remains available for modules that explicitly call it. It is not part of the host's source-reload or hard-restart sequence. A Lua module that owns native resources outside the plugin runtime must not rely on that registry being called automatically. This lifecycle gap remains open.

`lua/spec/` mirrors the Lua module tree with specifications and test support. It is available only in development. The checker includes the ordinary suite modules, while computed spec requires and negative type probes are handled by their dedicated tests. `make check` includes subprocess integration tests that start `lunette` with headless fixtures. It does not run a hardware acceptance session.

## Policy and mechanism

| Concern | Owner | Reason |
|---|---|---|
| Window and monitor handles, sinks, input delivery, outputs, layers, and capture | `lunette` | These operations cross native, compositor, or device boundaries. |
| Panel layout, surface picking, pointer behavior, and frame-rate policy | Lua modules and providers | Configurations can replace policy without changing the native API. |
| Contract identity, exact provider bindings, lifecycle, and resource cleanup | Native plugin runtime | These rules span service providers and must remain consistent within a runtime graph. |
| Service methods and configuration types | Luau contracts and definitions | The checker can validate local source shapes without inferring the complete runtime graph. |

The panel library adapts native window and monitor pixels to Lua-defined geometry and interaction. A monitor panel remains an in-scene quad because the native layer claim API accepts windows, not monitors. Interaction keeps pointer hover and keyboard focus separate; pointer motion does not implicitly take focus. These boundaries let a configuration change geometry and input policy without changing Wayland protocol behavior.

## Decisions

The standard library stays optional and separate from `lunette`. The native root exposes mechanism, while `mullion` contains replaceable policy and presentation. Keeping distinct roots avoids making a Lua implementation look like native mechanism and lets a configuration omit the library.

Neutral contracts stay separate from providers. A contract describes a service without importing the module that implements it. This allows plugins to typecheck against the service surface while keeping provider implementations replaceable.

The plugin API uses local capability and configuration types with runtime graph validation. A recursive inferred type for the complete provider graph exceeded Luau's 20,000 subtype-normalization budget even with an empty initializer. Changing compiler flags or limits was rejected. Local static checking remains useful, while declarations and the lifecycle graph validate whole-runtime wiring.

The native adapter contains erased casts. A mapped `Services<R>` and `Provisions<P>` authoring API is not used. `Context:require<T>(capability)` and init-only `Publisher:provide<T>(capability, value)` keep the public typing model direct and place runtime membership checks at the boundary.

## Known gaps

The host does not run the Lua teardown registry during source reload or hard restart. Non-plugin Lua modules that retain native resources can outlive their callbacks unless another owner releases those resources.

The desktop integration tests do not establish an actual XR or GPU-backed boot, host-desktop acceptance, or successful installed-session execution.

## Deliberately left open

The legacy `mullion` panel, interaction, laser, keyboard, tag, rules, adoption, and layout policy implementations remain in the source tree. Their removal or continued role as optional library modules has not been decided.

A 2D widget toolkit remains deferred. Larger settings and desktop interfaces fit better in Wayland clients than in a Lua widget framework. Further layout algorithms also remain open; the current library provides the arc layout and does not define a complete 3D layout set.

Deferred follow-up issues include #15, #36, #38, and #39. Their feature scope remains in the issue records. XR hardware and host-desktop acceptance remain human gates, and new desktop features remain outside this specification until their implementation and acceptance criteria are defined.
