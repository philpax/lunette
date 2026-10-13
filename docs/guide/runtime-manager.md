# Runtime manager

`desktop/manager` is the shipped desktop's plugin manager. The wrist menu's Plugins action toggles its panel, and the action shows whether the panel is visible. The panel's titlebar reads Plugins, and its X hides the panel. The panel moves like any other, as [Panel movement](desktop-configuration.md#panel-movement) describes. It is built on the public `lunette/ui` service, so it works with any provider of that contract. The [manager plugin page](../../lua/lunette-plugins/desktop/manager/README.md) lists its dependencies, and [manager behavior](../../lua/lunette-plugins/desktop/manager/docs/runtime-manager-behavior.md) specifies refresh, inspection, and recovery behavior.

The `desktop/manager` setting configures it; `lua/lunette-plugins/desktop/manager/config.luau` holds the options and defaults:

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/manager'] = {
      visible = true,
      position = vector.pack(0, 1.4, -1.2),
      view = 'graph',
    },
  },
}
```

`visible` shows the panel at start. `view` opens the entry list, `entries`, or the graph, `graph`. `width` and `height` are in metres, and `pixels` is the logical width; the logical canvas is at least 800x472. While the panel is visible, the manager refreshes its snapshot of the runtime every `refreshInterval` seconds, 0.25 by default. Opening the panel and pressing a control refresh at once, and a hidden panel does not refresh. The panel draws in the scene and is occluded by closer panels. Its schema and defaults are owned by [`config.luau`](../../lua/lunette-plugins/desktop/manager/config.luau).

## Session styling

The manager follows the current theme. Its graph and sidebar use the theme font and these colours: `success` for active entries, `warning` for loading, unloading, and blocked entries, `error` on `errorBackground` for failed and quarantined entries, `mutedForeground` for inactive, removed, and disabled entries, `focus` for the selection, and the two edge colours for relationships. A theme change keeps the panel, drafts, and focus.

The toolbar and editors have fixed sizes, so `lua/lunette-plugins/desktop/manager/widgets.luau` caps some theme tokens inside them. Each cap takes the smaller of the token and the bound:

- Toolbar buttons, 26 units high: padding at most 3 and `smallSize` at most 16.
- Search, text, and boolean fields, 34 units high: padding at most 5 and `bodySize` at most 20.
- The choice editor, 102 units high: row height at most 40, padding at most 5, spacing at most 6, and `bodySize` at most 20.

## Entries and graph

The panel opens on Entries, a list of entry ids with their state and whether they are protected. Selecting an entry shows its details. Enable, Disable, Reload, Recover, and Remove act on the selection. Inspect, Configure, and Catalog switch the sidebar.

Graph shows the entries as a graph of ownership and dependency relationships, and Entries returns to the list. Dragging the graph pans it, scrolling zooms around the pointer, and Zoom in, Zoom out, Focus, and Fit adjust the view. Providers, Consumers, All, and Affected choose which relationships to show, and Transitive follows them beyond direct neighbours. Search opens a text field with the shared keyboard and filters both views by name, identity, declaration, and diagnostic text. Clear filter and Clear selection reset those states. A dependency relationship names the provider the runtime actually bound, not a guess from the declared contract.

Inspect describes the selected instance: its intent, phase, owner, children, bindings, pending replacement, cleanup state, diagnostics, and the effects each activation acquired. It also lists the owner-scoped registrations that each broker holds for the instance, such as panels, focus targets, tags, rules, layouts, keyboards, and pointers. Inspection never calls plugin callbacks.

Every control works with the controllers, and none has a key binding.

## Configuration and recovery

Configure shows controls built from the selected entry's schema. A boolean is a button, a literal choice is a choice control, and a number, a string, or a new map key is edited in a text field with the shared keyboard. Confirm accepts a field edit, Cancel discards it, and Clear empties the field. Add appends an array element or starts a map key, Remove value removes an element, Reset restores the schema default, and Set and Unset toggle an optional value. Apply validates the whole draft and replaces the entry's configuration. A rejected draft stays in place with its error.

A string that is not valid single-line UTF-8 is edited in an escaped form: `\\`, `\n`, `\r`, `\t`, and `\xHH`. Confirm decodes only a field opened in that form. Callbacks and custom values are read-only, and Apply passes them through unchanged.

Replacing a configuration restarts the entry. If the new activation fails, the entry stays failed, and Recover retries the last configuration that was active. Replacement is not transactional: the old activation has already ended. Disable withdraws the entry and Enable restarts it. Reload restarts it with its current configuration. Remove disposes the entry; if its cleanup fails, the entry is quarantined, and its native resources are released only by restarting the session. Catalog lists every entry the session has known, and Load reinstalls a removed entry with its last definition and configuration.

The shipped desktop protects `desktop/manager`, `desktop/menu`, `desktop/keyboard`, `desktop/pointing`, and `desktop/actions`, with the providers and parent owners they are bound to. Protected entries cannot be disabled or removed, which keeps the wrist menu, the keyboard, pointing, and reload available.

## Custom compositions

`@lunette-plugin/management.start(entries, options)` starts a composition and returns `{ runtime, service }`, the plugin runtime and the `lunette/composition` service the manager uses. It installs that service as the reserved `composition` entry. It runs each factory and validates every entry's configuration before activating any, so an invalid configuration stops startup. `options.protected` lists entry ids to protect along with their providers and owners. The service manages only the entries the composition started with.

A composition that includes the manager also includes its frame, UI, theme, and menu providers, the UI provider's focus and surface providers, and the pointing and keyboard entries, and protects the manager and its input path. `desktop.run` in `lua/lunette-desktop/init.luau` is the reference.

## Known gaps

Changes last for the session. The manager writes no configuration file, downloads no package, and changes no source file; a source reload starts again from the configuration's entry list.

The native record of an activation's effects grows with every acquisition until the activation ends, so a long-lived activation that acquires repeatedly has inspection cost proportional to its history.

While a graph pan is held, the graph keeps the layout it had at the press and moves on release.
