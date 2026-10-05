# Runtime manager

The shipped desktop includes `desktop/manager`. F10 toggles its projected flat surface. The surface can be moved with the normal pointer grab controls. Its width, height, position, logical pixel width, initial visibility, and toggle key come from `lua/lunette-plugins/desktop/manager/config.luau`.

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

## Graph controls

A click selects an instance or relationship. Dragging the graph pans it. `+` and `-` zoom around the canvas centre. `/` starts a search; text changes the query, Backspace removes its last character, and Return ends text entry. `F` centres the selected instance. `R` clears the filters and fits the graph within the supported zoom range. Large graphs remain pannable when the minimum zoom cannot fit every node.

`P` shows providers required by the selected instance. `C` shows its consumers. `T` switches direct and transitive traversal. `I` includes dependent instances and owned descendants affected by a change. `A` restores the complete graph. Escape clears the selection and filter. Toolbar buttons expose these operations without typing.

Dependency relationships identify actual allocated providers and their published generations. They do not guess a provider from a declared service name. Ownership relationships identify child instances. Parallel bindings and self-loops have separate selectable routes. Search includes names, identities, declarations, blockers, and diagnostic text.

## Inspection

The sidebar describes the selected instance's enabled intent, phase, retirement, authority, owner, children, current bindings, failed activation bindings, replacement request, cleanup state, and diagnostics. It lists native effects by owner, source, activation, ordinal, and armed, cleaning, or disarmed state. The native source identifies the actual acquisition owner; it does not infer which broker operation caused it.

Broker inspection lists owner-scoped offers, handlers, listeners, panels, focus grants, tag holds and memberships, overrides, rule sources, placements, layouts, adoption resources, keyboards, lasers, and pointers. Logical registrations and native effects have separate counts. Broker snapshots label facts that cannot be observed without invoking user callbacks. Inspection never invokes an offer, rule resolver, filter, handler, or clock, and does not prune dead tag members. Independent inspection consumers suspend during their broker's outage and reconnect when a provider returns. Tag membership and exclusion status describes the retained registration and owner. Separate `targetLiveness` metadata reports raw target death or marks the observation unavailable rather than invoking a getter.

Previous and Next scroll the sidebar. Page Up, Page Down, and the arrow keys also scroll it. Omitted visual lines have an overflow indicator; scrolling keeps the remaining records reachable.

## Configuration and recovery

Configure opens schema-derived controls for the selected entry. A boolean toggles on click. A numeric or string row starts text entry; Return stores the draft value and Escape cancels text entry. Literal choices cycle on click. Vector components have separate numeric controls. Arrays and maps expose their elements; Add appends an array element or requests a map key, and Remove value removes an element. Reset restores the descriptor's bound default. Optional values can be set or unset when doing so preserves opaque data.

Callbacks, custom values, and undeclared opaque data remain read-only. A draft retains their exact references. The manager does not reconstruct the configuration from only visible controls. Apply validates the complete draft before requesting replacement. A parser or refinement error leaves the active configuration in place and appears in the sidebar.

An initializer failure after replacement leaves the entry failed. Recover explicitly retries the most recent configuration observed active. A failed recovery retains that history. Replacement is not transactional and does not restore the old activation automatically. Disable withdraws the entry's intent; Enable retries it. Reload uses its current configuration. Remove disposes the entry; cleanup failure instead retains a quarantined entry and its reservation. Catalog lists every known session entry. Selecting a removed entry and clicking Load installs its retained definition and configuration again. It does not resolve a new source path. A quarantined native resource requires a session restart.

A rejected replacement leaves the configuration unchanged. An accepted request can still raise if lifecycle draining reaches its action budget. In that case the current configuration and recovery history retain the accepted request, and the inspector reports the pending or failed state. An action error does not imply that no state changed.

The manager's provider, frame dispatch, surface broker, and pointing dependencies are protected from mutations that would remove the normal recovery controls. Protected entries remain inspectable. Direct calls to the native runtime bypass this composition-service policy.

## Custom compositions

`@lunette-plugin/management.start(entries, options)` returns one frozen record, `{ runtime, service }`, containing the runtime and the published composition service. It validates entry shapes, runs factories, and resolves managed configuration for every entry before activating any instance; a preflight error aborts startup. A factory runs once for its managed definition; provider outages and reloads retain that definition. `options.protected` names entry ids whose required providers and parent owners also need protection. The service's `add(entry)` accepts an already loaded definition or factory. No module download or arbitrary source-path resolver is added.

A custom frame installation can call `management.start` in its start callback and close the returned runtime in its stop callback. `frame.run` and `plugin.start` remain available for compositions without management. A custom composition that uses the projected manager includes the frame and surfaces providers and protects the manager and its input path.

## Known gaps

Changes affect the current session only. The manager writes no configuration file, downloads no package, unloads no native library, and changes no source file. Source reload starts from the configuration's entry list again.

Native disarmed-effect metadata retains the complete activation history. A long-lived activation with repeated acquisitions has inspection storage and snapshot cost proportional to that history, even after callable inverses are released. The history ends on the next activation, instance removal, or runtime closure. Existing snapshots retain their own copies after the native history is released.

Opaque custom references can remain mutable outside the manager. Preserving their identity does not make a detached copy of their contents. Runtime validation cannot prove that a custom validator is pure or that its claimed static type is correct.

Logic-headless tests cover the graph, controls, drafts, lifecycle service, and projected draw calls. Actual headset readability, GPU rendering, controller ergonomics, and installed-session acceptance require a running XR session.
