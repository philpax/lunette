# Runtime manager behavior

The manager is a `lunette/ui` panel that inspects and controls the active plugin composition. The entry requires the composition, frame, UI, theme, and menu contracts. Its VR workflow remains in [Runtime manager](../../../../../docs/guide/runtime-manager.md); shared lifecycle, protection, and snapshot guarantees remain in [Composition](../../../../../docs/dev/lua-api.md#composition) and [Architecture](../../../../../docs/dev/architecture.md#plugin-runtime).

## Visibility and refresh

The panel starts hidden by default and registers the Plugins action in the wrist menu. The action's selected state tracks panel visibility. The titlebar close action hides the panel. Opening the panel and pressing a control refresh the snapshot immediately. While visible, the manager refreshes at `refreshInterval`, which defaults to 0.25 seconds. A hidden panel does not refresh. Rebuilding snapshots every frame would repeat work unrelated to the display rate, so the manager uses a visible-only interval. The panel draws in the scene and is occluded by closer panels.

The `visible`, `refreshInterval`, `view`, `position`, `width`, `height`, and `pixels` fields and their bounds are defined in [`config.luau`](../config.luau). The same schema enforces a logical canvas at least 800x472 pixels.

## Inspection and controls

Entries lists each entry id, state, and protection status. Selecting an entry opens its details and lifecycle actions. The Graph view displays ownership and dependency relationships. It supports pan, zoom, search, and dependency traversal. A dependency edge names the provider the runtime actually bound, not an inference from the declared contract.

Inspect reports an instance's intent, phase, owner, children, bindings, pending replacement, cleanup state, diagnostics, and activation effects. It also reports owner-scoped broker registrations, such as panels, focus targets, tags, rules, layouts, keyboards, and pointers. Inspection does not invoke plugin callbacks. Independent child consumers inspect brokers so a broker outage does not withdraw the manager panel.

The configuration editor builds controls from the selected entry's schema. It applies a draft through composition preflight. The editor preserves callbacks and opaque values instead of replacing them with editable approximations. A rejected draft remains available with its error. Lifecycle requests follow the composition service: replacement ends the old activation before the new one starts, a failed initializer remains inspectable, and failed cleanup quarantines the entry. Recovery uses the last configuration observed active. Removal retains the entry's identity and order in the catalog; restoring it uses its retained definition and configuration.

Every control works with controllers. The manager registers no key or text handler.

## Styling and size limits

The manager follows the current theme. The graph and sidebar use `success` for active entries, `warning` for loading, unloading, and blocked entries, `error` on `errorBackground` for failed and quarantined entries, `mutedForeground` for inactive, removed, and disabled entries, `focus` for selection, and the ownership and dependency edge colours for relationships. A theme change keeps the panel, drafts, and focus.

The toolbar and editors have fixed sizes. [`widgets.luau`](../widgets.luau) caps theme tokens by taking the smaller of the token and the bound:

- Toolbar buttons are 26 units high; padding is at most 3 and `smallSize` is at most 16.
- Search, text, and boolean fields are 34 units high; padding is at most 5 and `bodySize` is at most 20.
- The choice editor is 102 units high; row height is at most 40, padding is at most 5, spacing is at most 6, and `bodySize` is at most 20.

## Known gaps

The native record of an activation's effects grows with every acquisition until the activation ends. Inspection cost is therefore proportional to the activation's acquisition history. While a graph pan is held, the graph keeps the layout it had at the press and moves on release.
