# Window arrangement

Arranges placed windows that have no pose, grouped by tag. Configure [`layout` and `tags`](config.luau) to select a named layout and the tags to arrange. A configuration can register another layout; [layout examples](../../../../examples/layout) include grid and follow arrangements.

| Requires |
| --- |
| `lunette/drops`, `lunette/frame`, `lunette/layouts`, `lunette/panels`, `lunette/placement`, and `lunette/tags` |

Windows with a saved `lunette.pose` or dropped during the current activation are excluded, so a later layout does not undo hand placement.

Arrangement runs on activation, placement or panel removal, tag changes, and layout registration changes. A drop itself does not trigger layout, because releasing one panel should not move its neighbours.

When a window belongs to multiple configured tags, a selected tag takes priority over every unselected tag, and configuration order breaks ties. This gives the visible workspace priority. With an empty `tags` list, every tag and untagged windows are included; with configured tags, windows outside those tags stay untouched.

The shipped layout is `arc`. Persistence and pose memory are separate entries; see [placement composition](../../../../docs/dev/standard-plugins.md#placement) and [layout registration](../../layouts/README.md).
