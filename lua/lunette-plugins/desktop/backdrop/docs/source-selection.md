# Source selection

The base environment requires only `lunette/frame`. Audio, process status, attention selection, and controls attach independently, so loss of a child does not remove the environment. The configured source modes and defaults are in [`config.luau`](../config.luau); runtime selection is implemented in [`selection.luau`](../selection.luau).

System mode reads the current default output mix. The provider does not change routing or volume. Application mode selects an exact registered `lunette.Process` instance. Window titles, application IDs, and PIDs are display labels, not source identity. An unavailable or silent process does not fall back to system audio, and process selections do not persist across sessions.

Attention mode selects the nearest visible window panel with a live process under a supported gaze ray, or the head ray when eye tracking is unsupported. If supported eye tracking is temporarily untracked, selection waits rather than switching to the head. Selection does not change focus or deliver input. The candidate must remain stable for the configured dwell period; the controls panel freezes selection, and tracking loss retains the last process.

Runtime choices live in the plugin definition and reset on source reload. Changed configured fields replace only their corresponding runtime choices. Persistent process preferences are not supported because a process handle cannot cross sessions. Restricted process observation can leave attribution unavailable; the source remains unavailable rather than selecting unrelated audio. See [audio acceptance](../../../../../docs/dev/audio.md#acceptance) for pending host checks.
