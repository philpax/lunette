# Window adoption

Starts adoption for eligible application windows as placed panels. Configure [`tags` and `filter`](config.luau) to set default placement tags or reject windows.

| Requires | Optional |
| --- | --- |
| `lunette/adoption` | `lunette/rules`, `lunette/drops`, and `lunette/panels` for the pose-memory child |

## Pose-memory child

The pose-memory child records a dropped window's pose for later adoption. Keeping recording and rule registration together ensures the pose is available before the first placement; a child outage disables pose memory without stopping adoption. Placement precedence is shared in [Standard plugins](../../../../docs/dev/standard-plugins.md#placement).
