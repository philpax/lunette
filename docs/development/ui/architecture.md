# Architecture

## Layers

The native API provides layout, text shaping, glyph generation, and SVG rasterisation. The UI host owns panels, retained nodes, mount points, layout synchronisation, drawing, pointer routing, focus, overlays, motion, and inspection. Kinds provide widget behaviour, visuals provide appearance, and authoring libraries produce host elements. The [host contract](../../../lua/lunette-contracts/ui-host.luau) defines the supported boundary.

Layout and text belong in Rust because flexbox, grid, Unicode line breaking, shaping, and font fallback have a long correctness tail. Widget behaviour, appearance, and authoring remain Lua policy. The host keeps the responsibilities that require one owner per panel: one tree, one draw order, one input route, and one focus state. A kind or authoring framework cannot independently replace one of those responsibilities without coordinating with the other content in the panel.

### Native mechanism

The [generated native declarations](../../../lua/lunette/init.luau) own the native API. Layout trees and the shared font and glyph resources belong to the Lua state. Layout trees support native callbacks, but the host's kind registration does not expose scripted layout or custom measurement. [Layout and text](layout-and-text.md#scripted-layout) states that boundary.

### Host

The [host provider](../../../lua/lunette-plugins/ui/host/README.md) owns the retained scene interface and publishes `lunette/ui-host`. It contains primitive kinds rather than the standard widgets. Surface interaction is shared with window and monitor panels through the interaction contracts; richer gesture claims and manipulation remain deferred in [#69](https://github.com/philpax/lunette/issues/69).

### Element kinds

The [standard kinds](../../../lua/lunette-plugins/ui/standard/README.md) register through the same public host contract as third-party kinds. The components provider publishes their typed constructors. A constructor names its kind, so an existing constructor reaches the current override rather than retaining an old registration.

### Visuals

Visuals record drawing primitives that the host can reuse. A custom volume receives a posed LÖVR pass every frame under a separate containment contract. [Rendering](rendering.md#drawing-api) distinguishes those paths.

### Authoring

The [React-like library](../../../lua/lunette-plugins/ui/react/README.md) is a library rather than a provider. It binds mount points and expands components into host elements. The host does not depend on its hooks or component model. Another authoring framework can use the same mount points, kinds, contributions, and panels.

## Capabilities

The [contract declarations](../../../lua/lunette-contracts/) own capability names, versions, and service types. Consumers obtain services through `context:require`; importing a provider's definition does not publish its service instance. Requiring the components provider orders activation after the standard kinds are available.

## Data flow

The host commits scheduled work once per frame in the frame service's scene update. It places presentations, renders scheduled mount points, expands dirty composites, applies layout changes, computes layout, and places overlays. Contributions render after the panel root, so they receive the props of that placement. Pointing follows the scene update. Drawing uses the resulting node state and recorded primitives.

An input callback can change a store or component state, but the scheduled render waits for the next scene update. There is no lazy commit before each key event, no commit after pointer delivery, and no post-layout mount adapter. Hover and press state can affect drawing without a component render. Consumers must not rely on a callback's structural changes being committed before another input event in the same frame.

Mounting schedules work rather than committing inside the mounting call. `MountHandle:committed()` queries whether the mount has committed; it is not a callback or a layout notification. Both effect hooks run after render submission and before host layout. [Authoring](authoring.md#hooks) records the consequences.

## Ownership and lifetime

Panels, registrations, overrides, and contributions belong to their creation owners. Destroying a panel unmounts its tree and runs effect cleanup without waiting for exit transitions. A contribution's subtree uses the contributing owner. A component instance is not a plugin-runtime owner, so the authoring library also runs its effect cleanup when that component unmounts while the panel remains live.

A kind override ends with its owner and exposes the preceding registration. When the current registration changes, the host remakes nodes and carries matching state, focus, hover, and capture by path and kind. [Kind overrides](extension.md#kind-overrides) states the matching rule. Removing an unmatched node ends its capture without activation.

Source reload unmounts component trees and discards their local state. A consumer reload remounts that consumer's trees. Reloading a provider also unloads its dependants. The host's saved world-panel poses are separate from component state; maintained arrangements are deferred in [#71](https://github.com/philpax/lunette/issues/71).

GPU resources acquired by the host are released with its context. Fonts and the native glyph atlas have Lua-state lifetime, not plugin-owner lifetime. Source reload retains the Lua state. A new state builds its own resources; there is no cross-state glyph cache.

## Protection and recovery

Runtime protection keeps the session's recovery controls reachable. The [runtime manager](../../users/runtime-manager.md) owns the user workflow and the distinction between protected entries and their providers.

Default appearance selects base kind registrations, base visuals, and the base theme while keeping accessibility settings. This permits recovery from an override without prohibiting replacement. It does not repair a broken host implementation.

## Errors

Component renders, kind handlers, visuals, and consumer callbacks run through protected boundaries. A failure is reported without stopping the rest of the frame. The exact fallback belongs to the failing boundary; no general guarantee requires every failure to retain previous output, install a placeholder, or retry only after inputs change. [Native Lua errors](../native/lua-api.md#errors) states the protected-call boundaries.

## The recovery plugin

The recovery plugin does not depend on the UI host or standard widgets. It draws its own ray-pickable controls, so a host failure does not remove the VR path to recovery. Its implementation and the runtime manager own the available recovery actions. The compiled-in safe mode does not require the toolkit.

## Rust and Lua boundary

Layout changes cross the native boundary in a batch, and layout returns changed placements. Shaped glyph ids and positions come from the native text implementation. Lua records visuals and packs draw instances; native code does not maintain per-node draw-buffer slots or an animation buffer. [Rendering](rendering.md#draw-cost) records the resulting cost boundary.

## Module placement

The [UI category guide](../../../lua/lunette-plugins/ui/README.md) names the supported provider and library entries. The [plugin boundary guide](../../../lua/lunette-plugins/README.md) defines supported imports. Internal host modules are not extension points.
