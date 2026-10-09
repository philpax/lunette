# Standard library

The Lua standard library is installed below `$PREFIX/share/lunette/lua/`. `@lunette-plugin` is the typed plugin facade, `@lunette-contracts` holds the neutral service contracts, `@lunette-plugins` holds every built-in plugin, and `@lunette-desktop` holds the entry list that the shipped configuration runs. Every policy the library ships is a plugin written against the public `lunette` API, and a configuration can replace or omit any of them. A configuration can also use `lunette` without loading any of it. [Plugin authoring](lua-api.md#plugin-authoring) and [Architecture](architecture.md#plugin-runtime) specify the plugin model.

## Module roots

The source tree is `lua/`. A session mounts the file-backed roots through LÖVR's virtual filesystem, and the checker resolves aliases from generated `.luaurc` files. [Build and development](build-and-development.md#module-roots) lists each root's alias, source directory, runtime resolution, and installation.

A relative require follows Luau's require-by-string rules in the checker and in a session alike. A module's path is its file's path without the extension, and a directory's `init.luau` is the module the directory names. `./` and `../` start from the directory holding the requiring module, and `@self` from the module itself, so in `keyboard/init.luau`, `./draw` is a sibling of `keyboard` and `@self/draw` is inside it. LÖVR's loader takes a path from the root of the virtual filesystem, so the session wraps `require` (`crates/lunette/src/require`) to resolve a relative path against the requiring chunk's file first. The resolved name, such as `@lunette-plugins/keyboard/draw`, is what `package.loaded` is keyed by. A relative path cannot leave the root it starts in, name the root itself, or contain `.` in a component; each raises at the requiring line. A chunk with no file, such as one `lunctl eval` sends, resolves as a module at the configuration root and has no `@self`.

The checker follows directory symlinks and keeps the module path the configuration used, so `dev/examples` reuses the checked-in examples without copying them.

## Contracts and providers

A contract module in `@lunette-contracts` declares a service type and exports a capability that pairs it with an authority-qualified name and schema number. Vocabulary shared by several contracts lives in a neutral contract module, so a service type never imports a provider. `@lunette-contracts/vocabulary` holds the surface and pointer types, the per-window pose property `lunette.pose` with `encodePose` and `decodePose`, and `PRECEDENCE`, the named precedences of rule sources. `@lunette-contracts/keys` holds the key vocabulary, read from `lunette.keyCodes()`, `lunette.modifierNames()`, and `lunette.lockingModifierNames()`, and the modifier and LÖVR key-name policy shared by the bindings provider and `desktop/input`. `@lunette-contracts/quad` holds flat-quad ray intersection.

Each built-in plugin is a provider or consumer module ([Provider modules](lua-api.md#provider-modules)) that validates its configuration with a schema. A replacement provider implements the existing contract; the contract is not weakened to fit it. Objects a provider method returns, such as panels, pointers, lasers, keyboards, and tags, outlive the call and check their own state. [Confinement](lua-api.md#confinement) states how consumer resources and overrides are owned and released.

The built-in providers:

| Id | Contract | Requires | Options |
|---|---|---|---|
| `frame` | `lunette/frame` 2 | none | none |
| `theme` | `lunette/theme` 1 | none | none |
| `themes` | `lunette/themes` 1 | none | none |
| `surfaces` | `lunette/surfaces` 1 | none | none |
| `panels` | `lunette/panels` 3 | theme | `style`, `priority`, `height`, `aspect`, `chrome`, `rendering` |
| `drops` | `lunette/drops` 1 | none | none |
| `focus` | `lunette/focus` 2 | frame | none |
| `bindings` | `lunette/bindings` 1 | frame | none |
| `interaction` | `lunette/interaction` 2 | drops, focus | `tuning`, `focusOnPress`, `drive`, `constrain` |
| `laser` | `lunette/laser` 1 | interaction, theme | `style`, `aim`, `triggerLock`, `buttons`, `readInput`, `draw` |
| `keyboard` | `lunette/keyboard` 3 | focus, theme | `rows`, `layers`, `style`, `modifierKeys`, `locks`, `onKey`, `drawKey` |
| `ui` | `lunette/ui` 2 | focus, surfaces, theme, frame | `theme`, `titlebarStyle`, `draw` |
| `menu` | `lunette/menu` 1 | none | none |
| `tags` | `lunette/tags` 1 | none | none |
| `rules` | `lunette/rules` 1 | none | `precedence` |
| `placement` | `lunette/placement` 1 | panels, rules, tags | `panelOptions` |
| `adoption` | `lunette/adoption` 1 | panels, placement, rules | `precedence` |
| `layouts` | `lunette/layouts` 1 | none | none |
| `errors` | `lunette/errors` 1 | none | `window`, `maxKeys`, `history`, `clock` |
| `pacing` | `lunette/pacing` 1 | none | `tuning` |
| `scale` | `lunette/scale` 1 | none | `tuning` |

`layout/arc` registers the arc layout with the layouts broker and takes `layout`, the name it registers, and `tuning`. `theme/standard` and `theme/arcade` register themes with the catalog and take no options. `desktop/keyboard` provides `lunette/keyboard-display` 1, and `desktop/persistence` provides `lunette/arrangement` 1. Each contract module under `lua/lunette-contracts/` declares its service, each plugin's `config.luau` or descriptor its options, and [Contracts](lua-api.md#contracts) states their guarantees. Consumers that follow a panel's life use the panels contract's `onAdded` and `onRemoved` listeners rather than any provider's private modules.

## Runtime themes

`@lunette-plugins/theme` provides `lunette/theme` over the square base theme in `lua/lunette-plugins/theme/base.luau`. [Runtime themes](lua-api.md#runtime-themes) specifies selection, notification, and the font cache.

`@lunette-plugins/themes` provides `lunette/themes`, a catalog of owner-scoped named registrations of complete themes. It selects nothing. `theme/standard` registers Dark and Light, which differ only in palette, and `theme/arcade` registers Arcade, which uses saturated colours, larger text and spacing, other radii, and the bundled Space Mono Regular face with its OFL licence. Arcade exists to show a theme that a plugin supplies and a configuration can disable.

`desktop/theme` selects a catalog theme by name. Its `preset` defaults to `dark`, and its sparse `overrides` apply over whichever theme it shows. It registers a `Theme: <label>` action in the session menu's Appearance group for each catalog entry and follows catalog changes. A choice updates the selector's one registration, so the new theme replaces the old one whole. The selector shows the user's choice while it is registered, then the configured theme, and otherwise holds no selection. A name that is not registered is logged once, after the first frame update so that entries registering later are not reported. The selector keeps the user's choice across activations in one runtime while the configured preset is unchanged.

The keyboard, panels, UI, and laser providers and the `desktop/hint`, `desktop/errors`, and `desktop/manager` consumers read the theme.

Panels, UI panels, and the keyboard draw rounded faces from `lua/lunette-plugins/theme/rounded-geometry.luau`. Initial hits test the same perimeter the mesh draws, and controls keep rectangular targets inside a conservative content clip. A titlebar can join its target's frame through `Surface.attachFrame`, so the pair draws one outline. Granted composition layers stay rectangular. [Rendering](rendering.md#rounded-scene-geometry) specifies the geometry, and [Joined frame attachments](lua-api.md#joined-frame-attachments) the attachment.

## UI toolkit

`@lunette-plugins/ui` provides `lunette/ui`: owner-scoped flat VR panels with buttons, single-line text fields, choices, lists, and regions, and a shared titlebar for any surface. It offers visible panels as surfaces and installs no draw handler; each consumer draws its own panels. [UI panels](lua-api.md#ui-panels) specifies the contract, and the [UI guide](../guide/ui.md) gives a contract-only example.

## Configuration descriptors

`@lunette-plugin/schema` derives runtime validation, editor metadata, and the Luau `Input` and `Output` types from one descriptor. Objects reject unknown fields and merge declared defaults. Arrays and maps replace whole, including when empty. Numbers and vectors require finite components. A callback is checked as a function. Errors carry a path and a code. A schema-backed definition exposes its metadata and a resolver that validates configuration without running the initializer. [Configuration schema](../guide/configuration-schema.md) documents the constructors.

## Default configuration

`etc/xdg/lunette/main.luau` calls `require('@lunette-desktop').run()`. The desktop is a list of entries, `{ id, definition, config }` or `{ id, factory, config }` for a definition made once per runtime. `lua/lunette-desktop/init.luau` is the source of truth for the entries and their order. It lists the providers above, `layout/arc`, `theme/standard`, `theme/arcade`, and the `desktop/` consumers below, all from `@lunette-plugins`. `entries()` answers the list.

`run { patches = { ... } }` applies patches with `plugin.compose`, binds the LÖVR callbacks with `frame.install`, and starts the list through `@lunette-plugin/management` at load. `run { entries = { ... } }` starts from another list. `compose(options)` answers the patched list without starting it. Composition runs before any callback is bound, so a malformed patch fails the configuration's load and safe mode reports it. [Composition](lua-api.md#composition) states the patch rules.

```lua
require('@lunette-desktop').run {
  patches = {
    { id = 'keyboard', disabled = true },
    { insert = { id = 'my-hud', definition = hud }, before = 'desktop/adoption' },
  },
}
```

`configure(id, definitionOrFactory)` is `plugin.configure`. It answers a function that takes the entry's configuration and returns a plain patch, so the checker reads the options against the entry's `Config` type. It does not call a factory.

`settings` configures the desktop consumers through their `Config` types. Its fields are `menu`, `decorations`, `arrange`, `persistence`, `keyboardDisplay`, `rules`, `monitors`, `hint`, `errors`, `pointing`, `pacing`, `workspaces`, `adoption`, and `manager`. Each maps to the `desktop/` entry of the same name, except `persistence`, which maps to `desktop/persistence`, and `keyboardDisplay`, which maps to `desktop/keyboard`. `lua/lunette-desktop/settings.luau` composes the consumers' own descriptors. Each setting expands to an ordinary configuration patch, and a setting and a patch for the same id raise an error. Unless `adoption` is given, `workspaces` also sets `desktop/adoption.tags` to the first workspace's name. [Desktop configuration](../guide/desktop-configuration.md) gives examples.

The shipped desktop opens no application. The development configuration inserts a terminal plugin ([The development loop](build-and-development.md#the-development-loop)).

The desktop consumers:

| Entry | Does | Options |
|---|---|---|
| `desktop/render` | Updates and draws panels in the `scene` phase. A child offers the shown panels as surfaces, so a surfaces outage stops pointing and leaves panels drawing. | None. |
| `desktop/hint` | Draws a line of text while no panel exists. | `text`, `position`, `size`, `foreground`, `font`. |
| `desktop/decorations` | Gives each native panel without its own chrome a shared UI titlebar with a close button, and monitor panels Restart mirror and monitor selection actions. Grip on the panel or titlebar, or trigger on the titlebar background, moves the panel. | `style`, overriding the UI provider's `titlebarStyle`. |
| `desktop/pointing` | Attaches both lasers, updates them against every offered surface in the `pointing` phase, and draws them in the `feedback` phase. | `laser`: `name`, `tuning`, `style`, `aim`, `triggerLock`, `readInput`. |
| `desktop/input` | Delivers physical keys and committed text through a physical focus source in the `delivery` phase. It requires no bindings provider. | None. |
| `desktop/keyboard` | Provides `lunette/keyboard-display`: one lazily made virtual keyboard with a shared titlebar, shown when a focused local field wants it. | `placement`: `distance`, `drop`, `tilt`. |
| `desktop/menu` | Renders the tracked wrist Menu button and scrollable action list through `lunette/ui` and invokes `lunette/menu` actions. Tracking loss closes it. | `hand`, `size`, `offset`, `haptic`, `expanded`. |
| `desktop/actions` | Registers Reload configuration. A child registers Keyboard, which toggles the keyboard display, so a display outage leaves Reload. | None. |
| `desktop/errors` | Shows the latest report of the error stream on a quad in the `overlay` phase. | `position`, `width`, `textHeight`, `columns`, `lines`, `background`, `foreground`, `font`. |
| `desktop/workspaces` | Holds a tag per workspace and hides panels of unselected workspaces. | `workspaces`, default one `main`; `follow`, default true. |
| `desktop/monitors` | Starts capture and places monitor panels in a row, including hotplugged monitors. A child adds mirrors to configured tags. | `select`, `placement`, `tags`. |
| `desktop/rules` | Registers its rule list with `rules:setRules`. | `rules`; the default sizes and places Firefox. |
| `desktop/persistence` | Saves and restores the arrangement and provides `lunette/arrangement`. A factory. | `file`, default `arrangement.state`. |
| `desktop/arrange` | Arranges placed windows that have no pose, tag by tag, with layouts from the layouts broker. A factory. | `layout`, default `arc`; `options`, keyed by layout name; `tags`, every tag when empty. |
| `desktop/adoption` | Installs the native pose source and adopts windows. A child writes a dropped window's pose to `lunette.pose`. | `tags`, default `{ 'main' }`; `filter`. |
| `desktop/pacing` | Sets each window panel's frame rate from its `lunette/pacing` pacer and pauses hidden monitor captures. | `pauseMonitors`, default true. |
| `desktop/scale` | Sets each output's scale from its `lunette/scale` chooser for the nearest shown window panel. | None. |
| `desktop/manager` | The runtime manager panel, described below. | `visible`, `refreshInterval`, `view`, `position`, `width`, `height`, `pixels`. |
| `desktop/theme` | The theme selector, described above. A factory. | `preset`, `overrides`. |

Each consumer's `config.luau` owns its schema and defaults. Geometric options are native vectors built with `vector.pack`, and colours are numeric lists.

### Placement

Placement is `desktop/workspaces`, `desktop/rules`, `desktop/persistence`, `desktop/arrange`, and `desktop/adoption`. The placement provider joins rules, panels, and tags: it resolves a window's properties, makes its panel, and holds the tags the properties name. Rule sources apply in ascending precedence: configured rules at `PRECEDENCE.rules` (100), the saved arrangement at `PRECEDENCE.persisted` (200), and the native pose property at `PRECEDENCE.native` (300). Saved state supplies pose, size, and tags; the native source supplies a hand-placed pose. The rule list and the saved arrangement must be registered before adoption resolves the first window, so a rules source a configuration inserts goes `before = 'desktop/adoption'`. Tags are held, so whichever entry names a workspace tag first makes it, and the entries need no other order.

Drops reach pose memory, persistence, and arrangement through `lunette/drops`, which the interaction provider emits to when a grab ends. None of them requires interaction.

`desktop/arrange` arranges when it activates, when a placement is announced, when a panel is removed, when a layout registers or unregisters, and when a tag changes. Its candidates are live placements made without a pose, less panels dropped while it was active and windows with a `lunette.pose` property. The chosen tags are taken selected first, then the rest, and each tag arranges its candidates that no earlier tag took, with the tag's own layout or the configured one and that layout's entry in `options`. A layout registered as `continuous` is also applied every frame in the `scene` phase. A missing layout is logged once per name.

A persistence state reads a versioned file written by `@lunette-plugins/arrangement/format`. A file it cannot read, or one from a newer version, is reported and never overwritten. A window is saved under its application id and a monitor under its id. A window holds a slot from the creation of its panel until it dies, so a window that closes and reopens returns to its slot. A monitor panel that appears later is restored as it appears. A saved entry that matches nothing is reported once per arrangement. The state is made at the first activation and kept across activations with the same `file`. The rules source and arrival listener are effects of the activation. `desktop/persistence` saves when a drop is announced and at quit; a quit-save failure is reported and does not veto the quit.

`desktop/workspaces` selects the first workspace already selected, or the first in the list. A panel in a workspace's tag and in no selected one is hidden through a visibility override, which it withdraws rather than overriding to show, so a panel another plugin hid stays hidden. With `follow`, a window placed into workspaces none of which is shown moves into the shown one. With more than one workspace, a child registers `desktop/workspace/<name>` actions in the Workspaces menu group, so a menu outage leaves selection and visibility unchanged.

### Pacing and scale

`desktop/pacing` passes each window panel's hidden state, the window's `contentType`, and whether its `commit` changed to a pacer kept for the window. It observes commits only while the window is unthrottled, because a throttled client's commits describe the throttle. With the default tuning, a hidden panel's window runs at 1 Hz, a hidden video, game, or busy window at 30 Hz, and a shown panel's window unthrottled. A window whose panel is removed returns to unthrottled. While `pauseMonitors` is true, a hidden monitor panel's capture is paused.

`desktop/scale` measures from the head to the centre of every shown window panel, takes the nearest for each `window.output`, and sets the output's scale when its chooser's step changes. An output with no shown window panel keeps its scale, and nothing changes while the headset reports no head.

Unloading either entry reverts what it set. A scale is restored only if it is still the one the entry set.

## Session composition and inspection

`@lunette-plugin/management` owns the running entries and their configuration and provides `lunette/composition`, whose service lists, enables, disables, reloads, configures, removes, restores, and recovers entries. Configuration is validated through the definition's resolver before any cleanup. A failed initializer stays failed and inspectable, and `recover` reloads the last configuration observed active. Replacement is not transactional, and a cleanup failure leaves a quarantined entry. The catalog keeps each known entry's identity and order after removal, and `restore` reinstalls it from its retained definition and configuration.

The service protects itself and the configured entries, following their current and failed provider bindings and parent ownership. `desktop.run` protects `desktop/manager`, `desktop/menu`, `desktop/keyboard`, `desktop/pointing`, and `desktop/actions`, so the controls needed for recovery stay available. Code that mutates the raw runtime bypasses this policy.

`Runtime:snapshot()` returns detached records without running callbacks or draining work: instances, declared capabilities, current and failed bindings, generations, activations, ownership, dependents, diagnostics, and effect states. Brokers expose `inspect()` through their contracts, returning primitive metadata about registrations and owners without invoking any user callback.

`desktop/manager` is a movable `lunette/ui` panel, hidden initially, with a Plugins titlebar. The Plugins menu action, `desktop/manager/open`, toggles it. It lists entries with their state and protection, and selecting one opens its details and lifecycle actions. A Graph view shows the dependency graph with pan, zoom, search, and dependency traversal. The sidebar shows bindings, effects, broker registrations, and a configuration editor that preserves callbacks and opaque values; Apply runs composition preflight. The manager refreshes its snapshots every `refreshInterval` while visible and registers no global key or text handler. Independent child consumers inspect each broker, so a broker outage does not withdraw the panel.

## Module lifecycle

Source reload runs every module again ([Reload](lua-api.md#reload)), so a module keeps no module-level state, and a non-plugin module that holds native resources releases them itself.

Each module's tests are in a `tests` directory beside it, as [CONTRIBUTING.md](../../CONTRIBUTING.md#lua-tests) states. `lua/lunette-desktop/tests` drives the shipped desktop: startup and ten production reloads, provider outages, persistence through hotplug and reopened windows, settings, protection, and each example configuration. The tests run over the fake native API in `lua/testing` and do not establish an XR or GPU-backed boot, host-desktop acceptance, or an installed session.

Safe mode is compiled into the binary and requires only `@lunette`, so a missing or broken module tree cannot prevent recovery.

## Policy and mechanism

| Concern | Owner |
|---|---|
| Window and monitor handles, sinks, outputs, layers, and capture | `lunette` |
| Panel layout, picking, pointer behaviour, and frame-rate policy | Providers and consumers |
| Contract identity, provider bindings, lifecycle, and cleanup | The native plugin runtime |
| Service and configuration types | Luau contracts and definitions |

The panels provider adapts native pixels to Lua geometry. Its `rendering` defaults to `'plane'`, so window content takes part in scene depth. `'layer'` puts windows into composition layers with scene fallback. Monitor panels stay in the scene because the layer claim API accepts windows only. Pointer hover never takes keyboard focus; with `focusOnPress`, a press does.

## Decisions

The Lua roots stay separate from `lunette`. Distinct roots keep a Lua implementation from looking like native mechanism and let a configuration replace any provider.

Contracts stay separate from providers, so plugins typecheck against a service without importing its implementation.

Panel lifecycle is announced through the panels contract. A consumer that imported the provider's private modules could not work with a replacement, and a module-global registry of per-panel cleanups outlives activations. A panel is released before its owner's effect is disposed, because the runtime withholds an owner's authority while its inverse runs, and a removal announced from the inverse would reach the owner's own listeners as if the owner were gone.

A saved slot is held by its window. Taking a slot on every resolve would let `rules:resolve` consume slots. Freeing a slot when the panel is removed would let a provider outage, which removes every panel while the windows remain, shuffle windows between slots.

The arrangement is saved on a drop and at quit. Saving on panel removal was rejected because removal happens mostly during outages, reloads, and unloads, when the desktop is coming apart. A drop is the moment the user finishes placing a panel.

The desktop is an installed root changed by patches. Consumers composed by a fixed sequence in `main.luau` were rejected: a configuration could not reuse one without copying it. Patches name what they change by a stable id. Unknown ids and two patches for one id raise, because a patch that matches nothing does not do what it says.

Typed settings expand to patches. A combined desktop plugin was rejected because it would require the union of its consumers' dependencies and lose independent outages.

Every shipped plugin is under `@lunette-plugins`. A provider's folder is its contract, and any other plugin's folder is its entry id, so the path follows from what a patch or log line names. `desktop/persistence` provides `lunette/arrangement`, so it is `@lunette-plugins/arrangement` under the provider rule and keeps its id. Grouping consumers by domain was rejected because the path would differ from the id.

Shared helpers live with what they describe. An optional root of helpers would make a shipped provider depend on a root an installation may lack. The key names are the native API's, read from `lunette-capture`'s `VirtualKey`, so they cannot drift from what the sinks emit; a hand-written table was rejected for that reason.

Configuration merges records and replaces everything else. A colour list or a vector is one value, and merging `{ 1 }` into `{ 0.5, 0.5, 1, 1 }` by position would make a colour nobody wrote. Descriptors replace inference from defaults because optional values, unions, callbacks, and empty collections need an explicit type.

Geometric values are native vectors. Numeric tables lose the geometric type and need scalar arithmetic.

Provider modules share one shape so a configuration varies, wraps, or replaces any provider the same way.

Placement is several entries, following the integration component of section 6.5 of the Cordis paper. One policy entry was rejected because replacing the layout, the rules, or persistence would mean copying all of it. Adoption's install and start stay together because a start without the native pose source loses hand-placed poses across reloads. `desktop/arrange` learns of placements from the placement contract, which carries the resolved properties; `panels:onAdded` reaches every panel without them.

A dropped panel leaves the arrangement. Re-arranging on a drop would move the other windows as the user lets go of one. A kept `lunette.pose` property also excludes a window, so a window dragged during an outage of `desktop/arrange` is not arranged again; a record in the drops broker would end with the broker's activation.

A window in several tags is arranged by its first selected tag, so its pose comes from a layout the user is looking at. Layout options are keyed by layout name rather than carried by the tag, because a tag is shared state and the options are one consumer's configuration.

Rendering, mirroring, and the hint are separate entries, so a configuration replaces one without the others. Offering panels is a child of `desktop/render` that requires surfaces, so a surfaces outage leaves panels drawing. Mirrors take the lowest free place in the row and are not re-laid, because the saved arrangement restores a mirror as it appears.

Workspaces are one default entry with one `main` workspace, so the shipped menu shows no Workspaces group until a configuration names a second. Its menu actions are a child so a menu outage does not reveal hidden windows. Workspace chords are not shipped because session controls must be reachable through VR input.

Pacing and scale are providers (issue #38), and the desktop entries read the scene and apply them. A different rule is a different provider, and a different reading of the scene is a different consumer. Both entries are on by default and revert on unload, because a disabled entry must not leave outputs at a step it chose.

A relative require resolves against the requiring file, as in the checker and editors. Resolving against the configuration root would let a plugin in a subdirectory check clean and fail to load. Replacing LÖVR's require with Luau's require library was rejected because it keys its cache apart from `package.loaded`, which reload clears.

A typed patch is a function per entry. A patch type discriminated by `id` needs an arm for inserted entries, which would accept a mistyped option for any shipped entry.

Small VR controls come from a replaceable `lunette/ui` provider, so a configuration can replace control policy without importing a widget implementation. Larger interfaces remain Wayland clients.

Menu actions are a broker separate from rendering, so the wrist menu, the UI provider, or the broker can be replaced independently. Enabled and selected state are explicit owner updates, so listing runs no action code. The keyboard display observes focus metadata rather than being required by each widget, which avoids a dependency cycle.

Pointer feedback draws in its own final `feedback` phase. Raising the pointing draw's order was insufficient because order applies only within a phase, and moving the pointing update after overlays would change interaction timing.

Shared UI geometry offsets controls, contents, and glyphs by 1 mm steps without depth writes, so coplanar parts do not conflict and depth does not accumulate across controls. Intersecting panels can show draw-order artefacts within that span; per-panel masks were not added.

A grab keeps the panel's pose relative to the controller. Upright-only movement was rejected after headset testing found it less usable.

The manager refreshes its snapshots on an interval while visible, because rebuilding them every frame repeats work unrelated to the display rate.

Every source is `.luau` because every source uses Luau syntax, and an editor that sees `.lua` reports the annotations as errors. The fork resolves `main.luau` first ([LÖVR integration](lovr-integration.md#mainluau-as-the-entry-point-under-luau)).

## Known gaps

The desktop tests do not establish an XR or GPU-backed boot, host-desktop acceptance, or an installed session. Geometry recorders do not rasterise edges, alpha, depth, or fonts. The theme and rounded-geometry gates in [Desktop configuration](../guide/desktop-configuration.md) remain pending.

## Deliberately left open

Pacing reads whether a panel is hidden, not whether it is in view, gazed at, or distant ([Rendering](rendering.md#frame-pacing)). Pacing by view direction risks a stutter as the head turns back, and the choice is left until it can be tried on hardware.

The arc is the only shipped layout. `examples/layout` holds grid and follow layouts as examples.

Issues #15, #36, and #39 hold deferred follow-up work.
