# Panel rendering

Updates and draws registered panels. Its optional surfaces child offers shown panels for pointer picking; if `lunette/surfaces` is unavailable, panels continue drawing but cannot be targeted by pointer input.

| Requires | Optional |
| --- | --- |
| `lunette/frame`, `lunette/panels` | `lunette/surfaces` for pointer surfaces |

The panel provider owns geometry and rendering mode. See [Window rendering](../../../../docs/guide/desktop-configuration.md#pointer-and-panel-appearance) and [Rendering](../../../../docs/dev/rendering.md).
