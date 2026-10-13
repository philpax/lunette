# Source selection

The backdrop base requires only `lunette/frame`. Its source-selection, audio response, and controls children own separate dependencies and lifetimes. Audio or analysis loss removes audio reactivity without withdrawing the environment. Panel or surface loss stops automatic attention selection. UI or menu loss withdraws the controls. Independent audio consumers do not depend on backdrop children.

The configured source mode is `system`, `application`, or `attention`. The schema in [`../config.luau`](../config.luau) owns the configured defaults and bounds. The selection implementation in [`../selection.luau`](../selection.luau) owns runtime policy.

## System source

System mode reads the current default output mix. The raw audio provider does not change application-to-device links, the default sink, or device volume. Its format, state, attribution, and graph behavior are specified centrally in [non-routing capture](../../../../../docs/dev/audio.md#non-routing-capture).

## Application source

Application mode retains an exact live `lunette.Process` handle for a registered session process. The application list uses window titles and application IDs as display labels, not identities. The numeric process id is a distinguishing label only. Selection and source equality use the process handle's logical identity.

An unavailable, silent, or ended process does not fall back to the system mix. The selected identity remains pinned. A dead process produces an ended reader rather than a replacement source. No process handle, PID, or label is serialized as a source preference.

## Attention source

Attention mode observes the nearest eligible offered surface under a supported eye-gaze ray, or under the tracked head ray when eye tracking is unsupported. When eye tracking is supported but temporarily untracked, selection does not fall back to the head ray. The target must be a visible live window panel with a live process. A monitor, UI surface, hidden panel, or dead process is not a target.

The pointer ray uses the eye/gaze pose when eye tracking is supported, otherwise the head pose. The attention child picks the nearest offered surface, then resolves it to a window panel and its registered process. The child does not change focus, deliver input, or change shared panel highlights. A dwell candidate must remain unchanged for the configured dwell duration. Completion commits in the next input phase. Changes to the source mode, ray source, candidate, or freeze state reset the dwell.

Opening the controls panel freezes attention selection. The panel reports that attention pauses while it is open. Tracking loss retains the last attended process; it does not replace the selection. Silence does not disqualify a process. A dwell badge is feedback only and is not offered as an input surface.

## Runtime choices

The factory keeps runtime choices in definition-local state. A provider reactivation preserves each choice while its corresponding configured value remains unchanged. A changed configured field replaces only that field's runtime choice. A new factory starts with the configured defaults. Source reload also creates new definition-local state, so runtime choices end at reload.

Application-name matching and PID-only selection are rejected because names are ambiguous and PIDs can be reused. A process handle identifies a session process instance. Persistent source preferences remain deferred because a process handle cannot cross sessions. [Desktop configuration](../../../../../docs/guide/desktop-configuration.md#audio-backdrop) describes the controls.

## Decisions

Audio and analysis have neutral contracts independent of the backdrop. A consumer acquires its own reader through those contracts, so disabling or losing a visual effect does not withdraw PCM from other consumers. Capture is lazy, so an unused provider does not open a host stream.

The backdrop uses a frame-only base with optional audio, attention, and controls children. Requiring all combined providers in the base was rejected because an audio or UI outage would remove the environment. Runtime application choices stay in factory state rather than module globals or serialized preferences.

Application choice holds the exact session process instance and does not fall back on silence or unavailable attribution. Application-name and PID-only selection were rejected because names are ambiguous and PID reuse changes identity. Persistent source preferences remain deferred because a process handle cannot cross sessions.

## Known gaps

The raw provider's live PipeWire acceptance remains pending. Restricted process observation, PID namespaces, proxies, or sandboxing can prevent process attribution. Unresolved sources remain unavailable rather than selecting unrelated audio. [Audio acceptance](../../../../../docs/dev/audio.md#acceptance) records the operator checks.

## Deliberately left open

Persistent source preferences and a catalog of visual effects are not implemented. A process handle cannot cross sessions, so persistent source preferences remain deferred.