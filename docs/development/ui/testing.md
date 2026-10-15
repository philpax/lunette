# Testing

## Ids and inspection

Every node has an id formed from its panel's name and the keys on its path from the root, such as `Plugins/sidebar/configure/rows/title`. Panel names are unique within the host, and the host rejects a second live panel with the same name. Keys come from components, as [Authoring](authoring.md#elements-and-children) describes. An unkeyed child contributes a positional segment such as `#2`, which changes when a sibling before it appears or disappears, so anything a test addresses has an explicit key. A node inside a portal has its id under its logical parent's path, and an item inside a node is addressed as the node's id followed by `@` and the item id.

The host's `inspect()` follows the inspection contract in [`lua/lunette-contracts/inspection.luau`](../../../lua/lunette-contracts/inspection.luau). It returns a registration for every panel and for every node and item, with:

- the id, the kind, the role, and the semantics;
- the owner of the node, and of each override and contribution that applies to it;
- local bounds, clip, elevation, and the world pose of the centre;
- the enabled state and the disabled reason;
- focus, hover, and capture state;
- each animation channel's current value and target, and whether the node is exiting;
- the index of a virtualised item;
- the fields that the kind's `inspect` function adds.

Inspection invokes no plugin callbacks and grants no authority.

Nodes outside their clip, such as list rows scrolled out of view, are reported with an empty visible area, so a test can tell an absent node from a hidden one. A virtualised list or grid reports every item with its index, materialised or not, and a test brings an item into view through `scrollIntoView` before it interacts with it.

## The test clock

Animations, holds, toast timeouts, and long presses read the host's clock. Tests substitute a clock that advances only when the test steps it, so a test of an exit animation or a hold-to-confirm button is deterministic and does not wait for real time.

## Test layers

### Component tests

Component tests render a component into a headless host and assert on the resulting nodes. They run in the Lua test runner with the real host, the real standard kinds, and the real native layout and text binding, because the project controls all of them. Drawing is not executed. A test drives a node through semantic events: `activate`, `context`, `drag`, `scroll`, `key`, and `text`.

```luau
test('a disabled pin button explains why', function()
  local mounted = harness.mount(BackdropControls { backdrop = fakeBackdrop { source = 'mix' } })
  local pin = mounted:find 'pin'
  expect.equal(pin.enabled, false, 'pin is disabled')
  expect.equal(pin.disabledReason, 'Pinning is available with the Attention source.', 'the reason')
end)
```

The backdrop service here is a fake, because the test is about the component and the service is another plugin's behaviour. `mounted:findByRole(role, name)` finds a node by its role and accessible name, which is how a test reads when it describes what a user sees.

### Kind tests

Kind tests cover each element kind's behaviour through semantic events, and its layout through the native binding. They include property-based tests where a kind has a property worth stating, such as a slider's value staying within its range for any sequence of drags, a scroll offset settling within the content for any sequence of scrolls and relayouts, and a gesture always having exactly one winner for any nesting of claims.

### Interaction tests

Interaction tests drive physical input through the fake native XR session in [`lua/testing/vr-ui.luau`](../../../lua/testing/vr-ui.luau). The helpers address nodes by id:

- `discover(id)` finds a node through inspection.
- `aim(interactor, id)` points a ray at the centre of the node's visible area, using the node's world pose, so it handles curvature, elevation, and transforms without a flat-panel formula.
- `poke(hand, id)` moves a tracked fingertip from in front of the node through the hover, activation, and release depths. The fake session provides the hand-interaction poke pose for it.
- `clickNode(id)` aims and presses with a controller across frames.
- `tab`, `arrow`, `activateFocused`, and `dismiss` drive focus traversal.

Every consumer panel has interaction tests that address its nodes by id.

### Rendering tests

Offscreen graphics tests in `make check-graphics` render panels through real LÖVR with the software Vulkan driver and read back pixels. They cover the toolkit shader: clipping at rounded corners and nested clips, clip depth ranges, surface shapes, elevation, paint order between overlapping siblings, coplanar content without depth fighting, glyph rendering from the atlas, and the absence of mirrored text. A test ties a rendered pixel to the hit mapping, by checking that the pixel at a node's inspected world pose belongs to that node.

### Theme tests

Each shipped theme is checked for the contrast rules in [Accessibility](accessibility.md#colour-and-contrast), for every pair of text and surface tokens and for non-text boundaries.

### Native tests

The layout and text binding has Rust tests in `crates/lunette/src/lua/tests/`, following the existing `textBoundaries` tests. They cover the batched change format, incremental relayout, rounding being disabled, composed positions in the result arrays, measure and arrange callbacks that raise or re-enter, text measurement at constrained widths, fallback, and the glyph budget.

## The native binding in tests

The layout and text binding is not pure: system fonts make measurements depend on the machine, and the glyph atlas is a GPU texture. The Lua test runner therefore registers the real layout and shaping implementation with only the bundled fonts and without system font discovery, so measurements are the same on every machine. Glyph atlas generation needs graphics, so it runs in the graphics tests.
