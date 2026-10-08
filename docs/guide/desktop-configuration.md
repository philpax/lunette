# Desktop configuration

The shipped configuration starts the default desktop with `require('@lunette-desktop').run()`. `lua/lunette-desktop/init.luau` owns the default entries and the configuration types. Its settings expand into patches for those entries. Each provider and consumer remains independently replaceable and retains its own runtime lifetime.

`lunette --dump-config` copies the shipped configuration and writes a `.luaurc` that names the installation's module roots. A custom configuration uses that directory. `lunette check` checks the configuration without starting a session. The checked configurations under `examples/desktop/`, `examples/keyboard/`, and `examples/layout/` demonstrate settings, provider replacement, and layout registration.

An alternate configuration starts with `lunette --config-path /path/to/config`. The path names a directory containing `main.luau` and, optionally, `conf.luau`. A relative path resolves from the working directory. The shipped desktop opens no application automatically. The repository's `dev/` configuration adds a terminal plugin for development; [The development loop](../dev/build-and-development.md#the-development-loop) states its launch command.

## Settings

`desktop.run` and `desktop.compose` accept the same options. Common consumer options go in `settings`, without importing each consumer's definition or factory.

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    menu = { hand = 'right' },
    decorations = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    arrange = { layout = 'grid', options = { grid = { columns = 3 } } },
    persistence = { file = 'desktop.state' },
    wristKeyboard = { placement = { distance = 0.45 } },
  },
  patches = {
    { insert = { id = 'grid-layout', definition = require './grid' } },
  },
}
```

Each section reuses the corresponding plugin module's exported `Config` type. The checker rejects a wrong value such as `menu = { hand = 'rigth' }`. `desktop.compose` parses the declared settings and expands them into entry patches before activation, so an invalid settings value aborts composition. When `plugin.start` or the native runtime starts definitions directly, configuration validation occurs as each instance activates; an invalid value fails that instance without aborting other entries. Unknown settings sections fail composition before LÖVR callbacks are bound.

| Settings section | Entry id |
|---|---|
| `menu` | `desktop/menu` |
| `decorations` | `desktop/decorations` |
| `arrange` | `desktop/arrange` |
| `persistence` | `desktop/persistence` |
| `wristKeyboard` | `desktop/keyboard` |
| `rules` | `desktop/rules` |
| `monitors` | `desktop/monitors` |
| `hint` | `desktop/hint` |
| `errors` | `desktop/errors` |
| `pointing` | `desktop/pointing` |
| `pacing` | `desktop/pacing` |
| `workspace` | `desktop/workspace` |
| `adoption` | `desktop/adoption` |
| [`manager`](runtime-manager.md) | `desktop/manager` |

The `menu` section configures the wrist Menu control in `desktop/menu`. Its descriptor and defaults are in `lua/lunette-plugins/desktop/menu/config.luau`. It accepts `hand`, `size`, a vector `offset`, `haptic`, and `expanded` panel dimensions. The default hand is `left`, the compact size is 0.115 metres, and the offset is `vector.pack(-0.03, -0.01, 0.125)`. The expanded panel defaults to 0.32 by 0.4 metres and 320 by 400 logical pixels, with a row height of 40 logical pixels. Haptics default to strength 0.3 and duration 0.05 seconds.

The `wristKeyboard` section configures only keyboard placement in `desktop/keyboard`. Its descriptor is in `lua/lunette-plugins/desktop/keyboard/config.luau`; `placement.distance`, `placement.drop`, and `placement.tilt` default to 0.55 metres, 0.35 metres, and `math.pi / 6` radians. It does not configure the `keyboard` service provider. A raw patch can replace that provider while settings configure the display provider, as in `examples/keyboard/main.luau`. `desktop/keyboard` publishes `lunette/keyboard-display` and lazily reuses one board. Focusing a local text field shows that board; switching fields keeps its pose. A manual show keeps it visible after editing ends. Explicit hide or X in the keyboard's shared top bar ends the matching field focus without discarding its draft.

`desktop/monitors` starts capture for every host monitor unless `settings.monitors.select` restricts the set. Capture uses the pinned WayVR `wlr-screencopy` implementation when available, with PipeWire and the host portal as the fallback. Direct capture does not require monitor selection. Each decorated monitor panel has Restart mirror and X controls in its titlebar. Select monitors appears only when that monitor does not use direct capture. Restart mirror dismisses and restarts that monitor's capture. Select monitors opens a fresh portal selection for hosts that require permission. Existing mirrors continue while the dialog is pending or cancelled. Cancellation does not reopen the dialog; another selection requires an explicit action. Source reload retains capture streams reused by the replacement configuration. Saved monitor placement restores the width and derives the height from the current monitor aspect ratio. The selection control disables while permission is pending and permits an explicit retry after failure. X stops mirroring and removes the panel without unplugging the host monitor. A window's X sends an application close request and leaves the panel present until the client unmaps it. Grip on panel content or any titlebar control moves the panel. Trigger on the non-button titlebar also moves it; trigger on a button activates that button. The controls follow the panel's pose and visibility. A UI-provider outage removes the controls without stopping capture. The host portal owns the permission dialog. Cursor pixels appear when the backend supports embedded cursor capture. Metadata-only cursor presentation remains unimplemented.

`settings.bindings` and the shipped `desktop/bindings` entry are removed. Reload uses the wrist menu. The neutral `bindings` provider remains available for custom input bindings. The `hand`, `size`, `offset`, and `haptic` fields of `settings.wristKeyboard` are removed; configurations place them in `settings.menu` instead. Composition reports these removed settings rather than ignoring them.

Settings follow the entry's configuration descriptor. Declared objects merge recursively with the entry's existing configuration. Arrays, maps, unions, and atomic values replace; an empty map clears its previous keys. Composition copies and freezes descriptor-declared object and collection containers. Callback and custom values retain their exact references, and non-plain native values such as vectors retain their values. For a factory entry, composition retains configuration layers until the factory supplies a definition. The definition's descriptor then determines merging and copying; managed preflight or instance activation performs validation. A setting and a raw patch cannot name the same entry, even when the patch only disables or replaces it. Composition reports both sources. One combined raw patch supplies the configuration when replacing that entry's definition.

## Wrist menu

`desktop/menu` renders the wrist Menu button and its expanded action list through the neutral `lunette/ui` contract. The tracked configured hand carries the control. A laser trigger press and release on Menu opens the action list; X in its shared top bar returns to the compact button. The list scrolls when its actions exceed the visible area. Tracking loss hides and closes the menu and cancels an armed action. A cancelled gesture cannot activate an action after tracking returns.

`desktop/actions` registers Keyboard and Reload configuration with the neutral `lunette/menu` broker. Keyboard toggles the shared keyboard display, and its selected state follows the display's visibility. An owner-scoped child registers Keyboard, so a display outage removes only that action. Reload configuration remains available to reload the configuration and its source modules. The shipped desktop registers no physical reload chord.

`desktop/manager` registers Plugins, which toggles the shared-UI manager panel named `desktop/manager`. The action's selected state follows panel visibility. The panel opts into the same top bar as window and monitor decorations, the expanded menu, and the keyboard display. Its contents draw in the scene phase and respect closer panels' depth. Its heading is Plugins, and X hides it and ends its active field focus. The graph and scrollable sidebar rows use custom regions; buttons, text fields, and choices use shared `lunette/ui` controls. Controller input reaches search, configuration editing, graph navigation, inspection, lifecycle actions, recovery, and catalog loading. Search and configuration text fields use the same desktop keyboard instance as application input. The manager registers no physical key or text handlers. Its schema rejects the removed `toggleKey` option and names Plugins in the session menu as its replacement. The [runtime manager guide](runtime-manager.md) describes the controls and session-only limits.

The [desktop example](../../examples/desktop/main.luau) inserts `hide-windows` and `save-menu`. They register Hide windows, Save arrangement, and Restore arrangement in the menu's Examples group. They are optional example consumers, not default session actions.

## Workspaces

The optional `workspaces` field reuses the configuration type of `@lunette-plugins/desktop/workspaces`. It inserts that consumer before `desktop/adoption`, so its placement listener observes windows present at boot.

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  workspaces = {
    workspaces = { { name = 'work' }, { name = 'web' } },
    follow = true,
  },
}
```

The first configured workspace is the initial selected workspace. Expansion patches `desktop/workspace` with its name and `desktop/adoption` with that name as the default tag. `lua/lunette-plugins/desktop/workspaces/config.luau` owns the defaults: `main`, `two`, `three`, and `four`, with `follow = true`. The list requires unique, non-empty names and at least one workspace. Each workspace accepts only `name`; `key` and `modifiers` are removed and report migration errors.

A child consumer registers each workspace name in the menu's Workspaces group. Selecting its row switches the selected workspace, and the row's selected state follows the tag selection. A menu outage removes those actions without changing workspace selection, visibility, or follow policy.

The shorthand adds one independently activated consumer. It does not merge the holder, adoption, menu, or placement plugins. It rejects a competing `settings.workspace`, `settings.adoption`, or raw patch for `desktop/workspace`, `desktop/adoption`, or `desktop/workspaces`. It also rejects a preconfigured holder or adoption entry, or an existing workspaces consumer in an explicit entry list. Raw patches remain available for a composition with different coordination rules.

Expansion does not rewrite explicit rule tags or persisted tags. Tags absent from the configured workspace list remain outside this consumer's visibility and follow policy. With `follow = true`, a newly placed panel already in a configured workspace follows the currently selected workspace, including a boot placement from a rule or saved arrangement. `follow = false` preserves that membership. Renaming a workspace does not migrate the saved arrangement; existing saved tag names still apply.

## Entry patches

`entries` replaces the default entry list. `patches` retains the full composition API: configure, replace, disable, or insert entries by stable id. `desktop.entries()` exposes the default list, and `desktop.compose(options)` returns the frozen expanded list without starting any plugins. A missing settings target in a custom list raises a composition error.

`plugin.configureEntry(id, target)(config)` makes a typed configuration patch for an actual entry id. The target is a definition or definition factory that supplies the configuration type. The helper never invokes a factory. The desktop exports the same helper as `desktop.configureEntry`.

```luau
local desktop = require '@lunette-desktop'
local persistence = require '@lunette-plugins/arrangement'

local entries = desktop.compose {
  patches = {
    desktop.configureEntry('desktop/persistence', persistence.factory) { file = 'desktop.state' },
  },
}
```

The supplied id may differ from the definition's name. The patch only carries the id and configuration; it does not replace the definition. A factory still runs once per runtime start, and its returned definition survives provider outages within that runtime. Separate starts construct fresh definitions.

The existing `plugin.configure(target)(config)` and `desktop.configure(target)(config)` remain compatible. They use the definition's name as the id and invoke a factory to discover that name. `configureEntry` is the appropriate helper when an id differs from a name or configuration must not construct a definition.

[Writing plugins](writing-plugins.md) describes provider substitution and plugin authoring. The [desktop example](../../examples/desktop/main.luau) combines settings, typed entry patches, workspaces, and inserted plugins.

## Pointer aim

The built-in laser provider stabilizes each controller's aim origin and direction before picking and drawing. The beam, landing indicator, UI input, and application mouse coordinates use the same stabilized ray. The controller pose used for panel grabs stays unfiltered. Trigger edges and scrolling remain immediate.

`lua/lunette-plugins/laser/aim.luau` owns the aim settings and defaults. Smoothing is enabled by default. `minCutoff` controls stationary smoothing in hertz; lower values suppress more jitter and add lag. `angularBeta` and `positionBeta` increase responsiveness during deliberate rotation and translation. `derivativeCutoff` controls speed-estimate smoothing in hertz. Tracking loss, a zero direction, or a frame interval above `resetAfter` clears history. Readers without a positive `dt` pass through without temporal smoothing.

The desktop's pointing settings override the provider defaults for both hands. The following configuration disables smoothing for comparison:

```luau
require('@lunette-desktop').run {
  settings = {
    pointing = { laser = { aim = { enabled = false } } },
  },
}
```

The same `aim` object accepts `minCutoff`, `angularBeta`, `positionBeta`, `derivativeCutoff`, and `resetAfter`. A patch for the `laser` provider configures its defaults; `laser:new` and `laser:attach` accept per-laser overrides. Pointer feedback draws in the final `feedback` phase, after scene geometry and overlay UI, including Plugins. OpenXR composition layers have separate runtime ordering; [Window rendering](#window-rendering) states that limit.

Trigger pressure above 10% holds the previously displayed ray while hovering a panel. A turn above 3 degrees or translation above 3 centimetres unlocks it for the remainder of the pull, allowing dragging. Releasing the trigger retains the held position for that frame, so a release does not move the click to a neighbouring control. Grip and spatial grabs bypass the lock. Tracking loss, a frame gap above `aim.resetAfter`, or removal of the target clears it. `lua/lunette-plugins/laser/trigger-lock.luau` owns these defaults. The independent `triggerLock` settings accept `enabled`, `threshold` as pressure from 0 to 1, `unlockAngle` in radians, and `unlockDistance` in metres:

```luau
require('@lunette-desktop').run {
  settings = {
    pointing = {
      laser = { triggerLock = { threshold = 0.1, unlockAngle = math.pi / 60, unlockDistance = 0.03 } },
    },
  },
}
```

Setting `triggerLock.enabled = false` disables the lock without disabling smoothing. Custom input readers can supply `Input.trigger`; omitting it bypasses the lock. Source reload applies changes to these Lua modules and settings without restarting the process. A plugin instance reload alone does not clear cached source modules.

## Panel movement

A grip press while pointing at a movable panel starts a grab and cancels an active trigger gesture. The panel follows controller-relative translation and rotation. While holding grip, the vertical thumbstick axis adjusts distance, and a second grip on the same panel scales it by hand separation. Releasing grip ends the grab and records placement for application panels.

`lua/lunette-plugins/interaction/config.luau` defines the reach and resize bounds. The `constrain` pose hook can supply a custom placement constraint.

## Window rendering

The built-in panels provider draws windows and monitor mirrors in the scene by default. This allows scene depth and session controls to cover window content. A typed patch `desktop.configureEntry('panels', require('@lunette-plugins/panels').definition) { rendering = 'layer' }` opts windows into OpenXR composition layers. Those layers can produce sharper text, but the runtime composites them after the scene, without its depth ordering. A window falls back to scene rendering while its layer claim is not granted. Monitor mirrors remain in the scene in either mode.

## Headset verification

Native capture and seat changes require a new process; source reload alone does not replace the running binary. `make run` builds and starts the repository development configuration. The manual acceptance checklist covers the following results:

- A gray ramp and familiar desktop content have matching brightness in the host display and mirror, including translucent window edges.
- A plane-rendered application window and the Plugins contents have the expected scene depth ordering. A closer panel occludes the manager, and the manager occludes farther panel content. No default window receives an OpenXR composition layer.
- Every configured monitor starts capture automatically. Direct capture opens no portal selection when the host supports it. Restart mirror in the monitor titlebar restarts that capture. Select monitors in the titlebar opens a fresh portal selection when required, both granted monitors update, cancellation retains existing capture, and an explicit retry remains possible. X removes the mirror panel without unplugging the monitor; a window's X permits an application confirmation dialog. The host cursor appears with embedded-cursor capture. A portrait monitor has the correct panel aspect, image orientation, and pointer coordinates.
- Keyboard legends, menu rows, titlebar actions, and Plugins controls remain complete without striped depth conflicts while moving the head and controllers. Laser rendering does not change panel visibility. The landing indicator remains visible over Plugins, the menu, the keyboard, and application panels.
- A stationary controller produces a steadier cursor with aim smoothing enabled than disabled. Slow aiming reaches small controls without sticking, and fast sweeps remain responsive. Trigger pressure above 10% holds the displayed target through press and release. Deliberate movement unlocks it without repeatedly relocking during the same pull. Text selection, graph panning, and application dragging remain usable. Tracking reacquisition does not sweep the cursor through the previous position. These checks cover both hands and the available headset refresh rates.
- Plugins toggles a readable entry list with runtime states, and its selected state follows visibility. The panel displays the shared Plugins heading and X. Entry selection, Disable, Enable, Graph, Configure, Catalog, and X work with controller input. Manager-open frame time is compared with manager-closed frame time.
- Grip on panel content or a titlebar button moves and rotates the panel with the controller. Trigger on the non-button titlebar moves it without application clicks; trigger on a button invokes only that action. The vertical axis adjusts distance, and two-hand resizing remains usable.
- Reload configuration can run repeatedly without duplicate `laser.left` or `laser.right` seat errors, stale menu controls, or additional keyboard instances.

Logic-headless tests do not establish these visual, timing, or comfort results.

## Known gaps

The manager exposes search and configuration fields through the shared UI controls and shared keyboard. `toggleKey` is removed; the manager configuration schema reports a migration diagnostic for configurations that still set it. Logic-headless behavior does not establish XR or GPU-backed behavior, host-desktop acceptance, or installed-session execution. Manual headset acceptance remains open for readability, controller ergonomics, shaping, bidirectional editing, and IME behavior.

## Decisions

Aim smoothing runs before picking so surface selection and rendered feedback use one ray. The adaptive low-pass follows the [1 Euro filter](https://gery.casiez.net/1euro/) approach with separate vector-speed gains for position and direction. It keeps the raw grab pose and button edges because filtering those would delay manipulation and clicks. Per-widget cursor smoothing would require each consumer to keep its rendering and dispatched coordinates synchronized. The shared provider avoids that duplication. The default gains require headset tuning; logic checks do not establish comfort.

The trigger lock uses analog pressure before the digital click edge because controller movement during a pull can move the cursor off a small control. It holds the shared ray rather than individual widget coordinates so native windows and UI panels behave alike. Coarse movement disables the lock until release to preserve dragging and avoid repeated locks. The thresholds require headset tuning.

Headed desktop panels use one opt-in titlebar implementation from the UI provider. Consumers supply the title, close callback, and extra actions rather than reconstructing the drawing and input controls. This keeps heading style and close behavior consistent while preserving each consumer's visibility and native close semantics.

The manager uses scene depth rather than overlay painting because it is a movable panel. Each shared UI panel backing writes depth. Controls, their contents, and glyphs occupy successive 1 mm rendering offsets without writing depth. The offsets follow drawing nesting rather than the number of sibling controls. This avoids coplanar depth conflicts, keeps transparent glyph bounds out of the depth buffer, and preserves the control order. Intersecting or nearly coincident panels can show draw-order-dependent details within the 3 mm span from the backing to its glyphs. This limited overlap is accepted rather than adding per-panel visibility masks. Pointer feedback remains a final overlay so its landing indicator is visible.

The wrist menu uses UI controls and menu actions so the shipped keyboard, reload, and workspace controls do not require physical key chords. The neutral bindings provider remains available for custom inputs. Keyboard placement stays in `wristKeyboard` for configurations that change the shared display without changing wrist geometry.

Settings expand to the existing stable-id patches so common configuration needs fewer imports without changing plugin failure, outage, or cleanup boundaries. The default retains its providers, consumers, and per-start factories.

Shorthand and raw patches cannot configure one entry together. Rejecting the collision avoids order-dependent overrides and keeps the advanced composition rule that each entry has one patch source.

Workspace expansion coordinates the initial holder and adoption defaults and runs the visibility consumer before adoption. It does not migrate explicit or persisted tags because those names are configuration and saved state, not aliases for the initial workspace.
