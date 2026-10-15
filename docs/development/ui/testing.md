# Testing

## Ids and inspection

Every node has an id formed from its panel's name and the keys on its path from the root, such as `Plugins/sidebar/configure/rows/s:title`. Keys come from components, as [Authoring](authoring.md#elements-and-children) describes, so ids stay stable across renders and do not depend on labels or registration order.

The host's `inspect()` follows the inspection contract in [`lua/lunette-contracts/inspection.luau`](../../../lua/lunette-contracts/inspection.luau). It returns a registration for every panel and for every node, with the node's id, kind, panel-local bounds, clip, elevation, world-space pose of its centre, enabled state, disabled reason, focus and hover state, and the fields that the kind's `inspect` function adds. Inspection invokes no plugin callbacks and grants no authority.

Nodes outside their clip, such as list rows scrolled out of view, are reported with an empty visible area, so a test can tell an absent node from a hidden one. A virtualised list reports only the rows that exist.

## Test layers

### Component tests

Component tests render a component into a headless host and assert on the resulting nodes. They run in the Lua test runner with the real host, the real standard kinds, and the real native layout and text binding, because the project controls all of them. Drawing is not executed. A test drives a node through semantic events: `activate`, `drag`, `scroll`, `key`, and `text`.

```luau
test('a disabled pin button explains why', function()
  local mounted = harness.mount(BackdropControls, { backdrop = fakeBackdrop { source = 'mix' } })
  local pin = mounted:find 'pin'
  expect.equal(pin.enabled, false, 'pin is disabled')
  expect.equal(pin.disabledReason, 'Available with the Attention source', 'the reason')
end)
```

The backdrop service here is a fake, because the test is about the component and the service is another plugin's behaviour.

### Kind tests

Kind tests cover each element kind's behaviour through semantic events, and its layout through the native binding. They include property-based tests where a kind has a property worth stating, such as a slider's value staying within its range for any sequence of drags, and a scroll offset staying within the content for any sequence of scrolls and relayouts.

### Interaction tests

Interaction tests drive physical input through the fake native XR session in [`lua/testing/vr-ui.luau`](../../../lua/testing/vr-ui.luau). The helpers address nodes by id:

- `discover(id)` finds a node through inspection.
- `aim(interactor, id)` points a ray at the centre of the node's visible area, using the node's world-space pose, so it handles curvature and elevation without a flat-panel formula.
- `poke(hand, id)` moves a tracked fingertip through the hover, activation, and release depths at the node.
- `clickNode(id)` aims and presses with a controller across frames.
- `tab`, `arrow`, and `activateFocused` drive focus traversal.

Every consumer panel has interaction tests that address its nodes by id.

### Rendering tests

Offscreen graphics tests in `make check-graphics` render panels through real LÖVR with the software Vulkan driver and read back pixels. They cover the toolkit shader: clipping at rounded corners and nested clips, curvature, elevation ordering, glyph rendering from the atlas, and the absence of mirrored text.

### Native tests

The layout and text binding has Rust tests in `crates/lunette/src/lua/tests/`, following the existing `textBoundaries` tests. They cover the batched change format, incremental relayout, text measurement at constrained widths, fallback, and the flat result arrays.

## Test fakes

The Lua test runner registers the layout and text binding. The binding is pure, so the runner registers the real implementation rather than a fake.
