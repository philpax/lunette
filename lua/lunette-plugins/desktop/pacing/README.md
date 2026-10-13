# Window pacing

Adjusts window rates from panel visibility and window activity. Hidden windows run at lower rates; shown windows are unthrottled. Configure [`pauseMonitors`](config.luau) to control whether hidden monitor captures pause.

| Requires |
| --- |
| `lunette/frame`, `lunette/panels`, and `lunette/pacing` |

Unloading restores windows to unthrottled operation and resumes captures paused by this entry. The [pacing provider](../../pacing/README.md) sets throttling and video exemptions. Observation uses panel visibility, not view direction, gaze, or distance.
