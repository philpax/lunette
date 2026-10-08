# Runtime manager

The shipped desktop includes `desktop/manager`. The Plugins action in the wrist menu opens its projected flat surface, and Close hides it. The surface can be moved with the normal pointer grab controls. Its width, height, position, logical pixel width, and initial visibility come from `lua/lunette-plugins/desktop/manager/config.luau`. The manager uses the public `lunette/ui` service from `@lunette-contracts/ui`; the built-in provider is `@lunette-plugins/ui`. The graph and scrollable sidebar content use custom regions. Buttons, text fields, and choices use shared controls with stable ids. The UI provider can be replaced by another implementation of the same contract. The manager configuration schema rejects legacy `toggleKey` with `toggleKey is removed; open Plugins from the session menu`.

```luau
require('@lunette-desktop').run {
  settings = {
    manager = {
      visible = true,
      position = vector.pack(0, 1.4, -1.2),
    },
  },
}
```

Grip moves and rotates the panel with the controller. While holding grip, the vertical thumbstick adjusts distance. A second grip scales the panel by hand separation. The [panel movement settings](desktop-configuration.md#panel-movement) define reach and resize bounds.

External runtime changes refresh while the manager is visible at `refreshInterval`, which defaults to 0.25 seconds. Opening the panel and control actions refresh immediately. The hidden panel does not poll snapshots. Drawing uses the retained controls between refreshes; snapshot and graph reconstruction do not run on every display frame. This bounds refresh work but does not establish headset frame-time performance.

## Entry management

The manager opens with Entries. Each row identifies the entry id, runtime state, and protection status. Selecting a row opens its details. Enable, Disable, Reload, Recover, and Remove apply to that selection. Protected entries cannot be disabled or removed. Inspect, Configure, and Catalog switch the sidebar content; configuration actions appear only in Configure, and Load appears only in Catalog. Close remains in the first toolbar row.

Search and dependency filters apply to both Entries and Graph. The Graph control opens the diagnostic relationship view; Entries returns to the list. `settings.manager.view = 'graph'` selects the graph initially. `lua/lunette-plugins/desktop/manager/config.luau` defines the settings and defaults.

## Graph controls

The graph custom region supports selection and dragging. Dragging pans the graph, and scrolling over it zooms around the pointer. Zoom in and Zoom out change the scale around the canvas centre. Focus centres the selected instance, and Fit fits the graph within the supported zoom range. Search opens a shared text field and the shared keyboard. Clear filter and Clear selection end those states. These controls remain reachable through controller input. Large graphs remain pannable when the minimum zoom cannot fit every node.

The toolbar switches between required providers, consumers, all graph relationships, and affected instances. A separate control switches between direct and transitive traversal. Clear filter and Clear selection reset the search and selection state. Previous and Next scroll the sidebar, configuration rows, and catalog. Catalog loading, entry lifecycle actions, and explicit recovery use the same controller-accessible controls. These actions do not use physical key bindings.

Dependency relationships identify actual allocated providers and their published generations. They do not guess a provider from a declared service name. Ownership relationships identify child instances. Parallel bindings and self-loops have separate selectable routes. Search includes names, identities, declarations, blockers, and diagnostic text.

## Inspection

The sidebar describes the selected instance's enabled intent, phase, retirement, authority, owner, children, current bindings, failed activation bindings, replacement request, cleanup state, and diagnostics. It lists native effects by owner, source, activation, ordinal, and armed, cleaning, or disarmed state. The native source identifies the actual acquisition owner; it does not infer which broker operation caused it.

Broker inspection lists owner-scoped offers, handlers, listeners, panels, focus targets and input sources, tag holds and memberships, overrides, rule sources, placements, layouts, adoption resources, keyboards, lasers, and pointers. Logical registrations and native effects have separate counts. Broker snapshots label facts that cannot be observed without invoking user callbacks. Inspection never invokes an offer, rule resolver, filter, handler, or clock, and does not prune dead tag members. Independent inspection consumers suspend during their broker's outage and reconnect when a provider returns. Tag membership and exclusion status describes the retained registration and owner. Separate `targetLiveness` metadata reports raw target death or marks the observation unavailable rather than invoking a getter.

Previous and Next scroll the sidebar. Omitted visual lines have an overflow indicator; scrolling keeps the remaining records reachable.

## Configuration and recovery

Configure opens schema-derived controls for the selected entry. Boolean rows use a button, and literal choices use a choice control. Numeric and string values, and map keys requested by Add, use a shared text field and the shared keyboard. Confirm accepts the field edit, Cancel discards that edit, and Clear empties its text. Apply is separate: it validates and submits the complete configuration draft. Add appends an array element or starts map-key entry, and Remove value removes an element. Reset restores the descriptor's bound default. Optional values can be set or unset when doing so preserves opaque data. Text-field drafts remain available when focus leaves the field. Rejected edits keep the draft and report the error.

Strings that already fit the single-line UTF-8 field remain literal. Other schema strings use a reversible printable-ASCII representation in the edit field: `\\` for a backslash, `\n`, `\r`, and `\t` for common control characters, and `\xHH` for other bytes. Confirm decodes only edits opened in that escaped representation. Ordinary literal strings do not interpret backslashes. Invalid escape sequences retain the pending text and diagnostic. The original string bytes remain unchanged until a successful Confirm changes the draft, followed by Apply.

Callbacks, custom values, and undeclared opaque data remain read-only. A draft retains their exact references. The manager does not reconstruct the configuration from only visible controls. Apply validates the complete draft before requesting replacement. A parser or refinement error leaves the active configuration in place and appears in the sidebar.

An initializer failure after replacement leaves the entry failed. Recover explicitly retries the most recent configuration observed active. A failed recovery retains that history. Replacement is not transactional and does not restore the old activation automatically. Disable withdraws the entry's intent; Enable retries it. Reload uses its current configuration. Remove disposes the entry; cleanup failure instead retains a quarantined entry and its reservation. Catalog lists every known session entry. Selecting a removed entry and clicking Load installs its retained definition and configuration again. It does not resolve a new source path. A quarantined native resource requires a session restart.

A rejected replacement leaves the configuration unchanged. An accepted request can still raise if lifecycle draining reaches its action budget. In that case the current configuration and recovery history retain the accepted request, and the inspector reports the pending or failed state. An action error does not imply that no state changed.

The shipped composition protects `desktop/manager`, `desktop/menu`, `desktop/keyboard`, `desktop/pointing`, and `desktop/actions`, when present, and the providers and parent owners reached through their actual current or failed bindings. This retains the wrist menu, shared keyboard, pointing, and reload recovery path. Optional broker inspection consumers do not protect every inspected provider. Protected entries remain inspectable. Direct calls to the native runtime bypass this composition-service policy.

## Custom compositions

`@lunette-plugin/management.start(entries, options)` returns one frozen record, `{ runtime, service }`, containing the runtime and the published composition service. It validates entry shapes, runs factories, and resolves managed configuration for every entry before activating any instance; a preflight error aborts startup. A factory runs once for its managed definition; provider outages and reloads retain that definition. `options.protected` names entry ids whose required providers and parent owners also need protection. The service's `add(entry)` accepts an already loaded definition or factory. No module download or arbitrary source-path resolver is added.

A custom frame installation can call `management.start` in its start callback and close the returned runtime in its stop callback. `frame.run` and `plugin.start` remain available for compositions without management. A custom composition that uses the projected manager includes its frame, UI, menu, and composition providers, the UI provider's focus and surface dependencies, and the pointing and keyboard path. It protects the manager and its input path.

## Known gaps

Changes affect the current session only. The manager writes no configuration file, downloads no package, unloads no native library, and changes no source file. Source reload starts from the configuration's entry list again.

Native disarmed-effect metadata retains the complete activation history. A long-lived activation with repeated acquisitions has inspection storage and snapshot cost proportional to that history, even after callable inverses are released. The history ends on the next activation, instance removal, or runtime closure. Existing snapshots retain their own copies after the native history is released.

Opaque custom references can remain mutable outside the manager. Preserving their identity does not make a detached copy of their contents. Runtime validation cannot prove that a custom validator is pure or that its claimed static type is correct.

During a captured graph pan, the manager retains the published graph geometry and drawing until release or cancellation. This avoids cancelling the gesture when the custom region's items change. The graph moves on release rather than continuously during the drag. Toolbar navigation and graph scrolling cancel a pending graph gesture before changing its view. A pending click resolves against the graph displayed at press, and a removed instance is not replaced by a newer instance with the same entry id.

The graph, controls, drafts, lifecycle service, and projected drawing remain subject to manual headset acceptance. Headset readability, GPU rendering, controller ergonomics, and installed-session behavior are not established by this guide.
