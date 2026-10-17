# Testing

## Ids and inspection

Tests address keyed nodes rather than fixed screen coordinates. The host's node id combines its panel name with the keyed path, and overlays retain their logical opener's path. Unkeyed wrappers can be traversed by the host, but explicit stable keys remain necessary for content a caller or test addresses.

The [host contract](../../../lua/lunette-contracts/ui-host.luau) owns discovery operations. `inspect` reports panels, overrides, and contributions. `inspectNodes` separately reports role-bearing nodes with semantics, layout boxes, and supported state. Keeping node inspection separate avoids a panel recursively displaying its own growing inspection list.

Node inspection can call a kind's semantics function under a protected call. It does not draw visuals, and it grants no authority over another owner's panel. It does not promise an item registry, every animation channel, offscreen virtualised items, or a world-pose matrix in each inspection record. A live node handle provides geometry needed for an input test.

## The test clock

Tests step existing frame fixtures with explicit deltas rather than waiting for wall-clock time. The host does not expose a public clock-injection service. Native glyph generation uses workers, so tests waiting for glyph readiness use bounded conditions rather than assuming a fixed number of frames or sleeping.

## Test layers

The [build and development guide](../build-and-development.md#lua-tests) owns test commands and fixture conventions. [Offscreen graphics tests](../build-and-development.md#offscreen-graphics-tests) use real LÖVR with a software Vulkan driver and require no live headset.

### Component tests

Component tests verify rendered node behavior with the existing Lua fixtures. They must respect deferred mounting and scene-update commits. An effect is not a post-layout barrier, and `committed()` is queried rather than registered as a callback. Checked tests beside the [authoring library](../../../lua/lunette-plugins/ui/react/tests/) are the reference rather than an unimplemented generic harness API.

### Kind tests

Kind tests exercise real registrations through their public host behavior. Important invariants include bounds on controlled values, valid grapheme boundaries after edits, owner cleanup, and the separation between cancellation and activation. A property-based test is useful when it checks an invariant independently of the implementation.

### Interaction tests

The [VR UI helpers](../../../lua/testing/vr-ui.luau) drive the fake native session and locate controls through inspection and node handles. Tests use the helpers actually exported there, not a copied inventory of proposed aim, poke, grab-sphere, and traversal methods.

A capture test needs to cover release and cancellation, not only initial press. An override during a drag must carry matching capture and release it on the replacement node. Removal of an unmatched node must not activate it. Deferred gesture arbitration and pick assistance in [#69](https://github.com/philpax/lunette/issues/69) and [#70](https://github.com/philpax/lunette/issues/70) are requirements, not existing test coverage.

### Rendering tests

Offscreen rendering verifies pixel behavior that node inspection cannot establish, including text orientation, clipping, depth, fading, and custom-volume state restoration. A test claiming drawing and picking agreement must exercise the real mapping rather than repeating a flat-panel formula in its oracle. Fixed curved meshes and transparent overlap retain the limits in [Rendering](rendering.md).

### Theme tests

Theme checks use the contrast requirements in [Accessibility](accessibility.md#colour-and-contrast). Coverage of token pairs does not prove every custom visual or translucent background. Headset checks remain necessary for legibility, stereo separation, and interaction comfort.

### Native tests

The [native Lua tests](../../../crates/lunette/src/lua/tests/) and [UI layout tests](../../../crates/lunette-ui/src/layout/) own native behavior. Native scripted callbacks do not imply a host registration path. Native glyph-cache tests must distinguish page-idle eviction and Lua-state lifetime from unimplemented reference counting or cross-state caching.

## The native binding in tests

The test runner can use the real layout and shaping implementation without system-font discovery. This avoids machine-dependent font selection while preserving the native algorithms. Glyph field generation runs on the CPU; texture upload and shader sampling require the graphics fixture. Tests should keep those boundaries explicit rather than substituting a fake for the behavior being checked.
