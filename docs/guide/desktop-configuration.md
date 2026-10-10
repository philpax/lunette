# Desktop configuration

The shipped configuration starts the default desktop with `require('@lunette-desktop').run()`. `lua/lunette-desktop/init.luau` owns the default entry list, and `lua/lunette-desktop/settings.luau` the settings types. Settings configure those entries by id, patches insert, replace, or disable them, and each provider and consumer stays independently replaceable.

`lunette --dump-config` copies the shipped configuration and writes a `.luaurc` that names the installation's module roots. `lunette check` checks a configuration without starting a session. `lunette --config-path DIR` starts the configuration in `DIR`, which holds `main.luau` and optionally `conf.luau`; a relative path resolves from the working directory. The shipped desktop opens no application. [The development loop](../dev/build-and-development.md#the-development-loop) describes the repository's `dev/` configuration, which adds a terminal.

## Settings

`desktop.run` takes `settings` and `patches`. Settings configure entries by id, without importing their modules:

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  settings = {
    laser = { aim = { enabled = false } },
    ['layout/arc'] = { tuning = { radius = 2 } },
    ['desktop/menu'] = { hand = 'right' },
    ['desktop/decorations'] = { style = { barColor = { 0.3, 0.12, 0.2, 0.95 } } },
    ['desktop/persistence'] = { file = 'desktop.state' },
    ['desktop/keyboard'] = { placement = { distance = 0.45 } },
  },
}
```

Every default entry that takes options has a setting under its id, and an entry without options has none. A setting has the type of its entry's `Config`, so the checker rejects a value such as `['desktop/menu'] = { hand = 'rigth' }`. Composition parses the settings when the configuration loads and raises on an invalid value or an unknown id. Each entry's defaults are in its `config.luau` under `lua/lunette-plugins/`.

A setting merges into its entry's configuration through the entry's schema: declared objects merge field by field, and arrays, maps, unions, and scalar values replace. A setting and a patch cannot name the same entry; composition raises an error naming both. Replacing an entry's definition and configuring it therefore happens in one patch.

## Wrist menu

`desktop/menu` draws a Menu button on the configured hand. Trigger on it opens the action list, and X in the list's titlebar closes it. Losing the hand's tracking hides and closes the menu and cancels a pending press. The menu shows the actions that plugins register with `lunette/menu`:

- `desktop/actions` registers Keyboard, which toggles the shared keyboard, and Reload configuration, which reloads the configuration and its source modules.
- `desktop/manager` registers Plugins, which toggles the [runtime manager](runtime-manager.md).
- `desktop/theme` registers one row per theme in the Appearance group.
- `desktop/workspaces` registers one row per workspace when more than one is configured.

A selected row shows the state it toggles. The shipped desktop binds no key chords.

`desktop/keyboard` provides `lunette/keyboard-display`, one shared keyboard reused across fields and applications. Focusing a UI text field shows it. Hiding it ends that field's focus and keeps the field's text. The `desktop/keyboard` setting places it; the `keyboard` entry is the provider that builds it, and a patch can replace that provider, as `examples/keyboard/main.luau` does.

## Monitors and titlebars

`desktop/monitors` mirrors every host monitor, or those named in the `desktop/monitors` setting's `select`. Capture uses wlr-screencopy when the host supports it, and otherwise the desktop portal and PipeWire, which ask the user for permission. A monitor's titlebar has Restart mirror, which restarts its capture; Select monitors, shown only for portal capture, which asks the portal again; and X, which stops the mirror and removes the panel. Cancelling the portal dialog keeps the existing mirrors. Stopping the screen share from the host desktop stops the portal mirrors, and lunette asks the portal again for the monitors it still mirrors; a portal that remembers the grant restores it without a dialog. A window's X asks the application to close, and the panel stays until the application unmaps it.

Saved monitor placement restores the panel's width and derives its height from the monitor's current aspect ratio. Source reload keeps the capture streams that the new configuration still uses.

## Runtime themes

`desktop/theme` selects a theme from the `lunette/themes` catalog and applies it through `lunette/theme`. Its configuration has `preset`, a catalog name defaulting to `dark`, and `overrides`, which change fields of the chosen theme. The shipped themes are plugins: `theme/standard` registers Dark and Light, and `theme/arcade` registers Arcade, with its own palette, font, metrics, and radii. [Adding a theme](writing-plugins.md#adding-a-theme) shows a configuration that adds a theme and removes Arcade.

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/theme'] = {
      preset = 'light',
      overrides = { radii = { uiControl = 4 } },
    },
  },
}
```

The Appearance group has a `Theme: <label>` row for each registered theme, in catalog order. Choosing one changes the theme in place, without restarting any plugin. A choice lasts for the session and is not saved. The selector shows the chosen theme while it is registered, and otherwise the configured one. Disabling `theme/arcade` while Arcade is chosen shows the configured theme, and re-enabling it shows Arcade again unless the user chose another theme in between. A name that no plugin registers is logged as a warning after the first frame. Reload configuration and a changed `preset` return to the configured theme; an edit to `overrides` alone keeps the session's choice. Disabling `desktop/theme` returns the provider to its square base theme.

`overrides` takes sparse `colors`, `typography`, `metrics`, and `radii` objects. `lua/lunette-plugins/theme/descriptors.luau` owns their fields and validation. Colours are RGBA arrays with components from 0 to 1. Text sizes, row height, and titlebar height are positive; padding, spacing, borders, gaps, and radii may be zero.

`overrides.typography.font` is `{ kind = 'default' }` or `{ kind = 'file', file = path, size?, spread? }`. A file font's `size` and `spread` default to 32 and 4, and `default` takes no other fields. `file` is a path in LÖVR's virtual filesystem. A missing font file fails the selector's activation, and the provider shows the base theme until a valid configuration is applied.

## Workspaces

`desktop/workspaces` shows the windows of one workspace at a time. The default is one workspace, `main`, with no menu rows.

```luau
require('@lunette-desktop').run {
  settings = {
    ['desktop/workspaces'] = { names = { 'work', 'web' }, follow = true },
  },
}
```

Each workspace is a tag. Names are non-empty and unique, and the first workspace is selected at start. A window placed into no workspace joins the selected one, however the workspace list was configured; adoption gives new windows no tag unless its `tags` name one. With more than one workspace, the Workspaces group of the menu has a row for each. With `follow = true`, the default, a newly placed panel in a configured workspace moves to the selected one; `follow = false` leaves it where a rule or the saved arrangement put it. Tags outside the configured list are not shown or hidden by this consumer.

## Entry patches

`patches` replace, disable, or insert entries by id. `desktop.compose(options)` returns the patched list without starting anything, and `desktop.compose()` returns the default list, for tests and tools that inspect a composition. An entry's `definition` is the `definition` field of the plugin module's record:

```luau
desktop.run {
  patches = {
    { id = 'keyboard', definition = require('./split').definition },
    { id = 'theme/arcade', disabled = true },
    { insert = { id = 'my-hud', definition = require('./hud').definition, config = { scale = 2 } } },
  },
}
```

A definition can be a factory, which builds a fresh definition each time the runtime starts and keeps it across provider outages within that runtime. [Configuring a built-in plugin](writing-plugins.md#configuring-a-built-in-plugin) describes patches, and [`examples/desktop/main.luau`](../../examples/desktop/main.luau) combines settings, workspaces, and inserted plugins.

## Pointer aim

The laser provider smooths each controller's aim before picking and drawing, so the beam, landing indicator, UI input, and application pointer coordinates use one ray. The grab pose, button edges, and scrolling are not filtered. `lua/lunette-plugins/laser/aim.luau` owns the settings and defaults:

- `enabled` turns smoothing on or off.
- `minCutoff`, in hertz, sets stationary smoothing; a lower value suppresses more jitter and adds lag.
- `angularBeta` and `positionBeta` raise responsiveness during deliberate rotation and translation.
- `derivativeCutoff`, in hertz, smooths the speed estimate.
- `resetAfter`, in seconds, is the frame gap that clears the filter, as tracking loss does.

The `laser` setting configures them for both of the desktop's lasers, and `laser:attach` takes overrides for the lasers another plugin makes. This configuration disables smoothing:

```luau
require('@lunette-desktop').run {
  settings = {
    laser = { aim = { enabled = false } },
  },
}
```

The trigger lock holds the displayed ray once trigger pressure passes `threshold`, so a click lands on the control the user aimed at. Turning more than `unlockAngle` radians or moving more than `unlockDistance` metres releases the lock for the rest of the pull, which keeps dragging possible. Grip grabs ignore the lock. `lua/lunette-plugins/laser/trigger-lock.luau` owns the defaults: `threshold = 0.1`, `unlockAngle = math.pi / 60`, and `unlockDistance = 0.03`. `triggerLock = { enabled = false }` disables it.

```luau
require('@lunette-desktop').run {
  settings = {
    laser = { triggerLock = { threshold = 0.2 } },
  },
}
```

Pointer feedback draws in the final `feedback` phase, over scene geometry and overlay UI.

## Panel movement

Grip while pointing at a movable panel grabs it and cancels any trigger gesture. The panel follows the controller's translation and rotation. While gripping, the thumbstick's vertical axis changes distance, and a second grip on the same panel scales it by hand separation. Releasing grip drops the panel and records its placement. Trigger on a titlebar outside its buttons also moves the panel. `lua/lunette-plugins/interaction/config.luau` defines the reach and resize bounds, and the interaction provider's `constrain` hook can restrict where a carried panel goes.

## Window rendering

The panels provider draws windows and monitor mirrors in the scene, where they take part in depth testing with other panels and session controls. The `panels` setting `{ rendering = 'layer' }` gives windows backend-owned composition layers instead. Layers can show sharper text, but the backend composites them after the scene, without depth ordering. A window whose layer claim is not granted falls back to the scene. Monitor mirrors always draw in the scene.

Scene content rounds its corners with the theme's `window` and `monitor` radii, and its pointer hits follow the same outline. Dark and Light keep monitors square, and Arcade rounds them by 0.012 m. The panels provider's style `windowRadius` and `monitorRadius` override the theme. A flat panel with a titlebar draws the titlebar and body as one outline. Layer content, and the titlebar of a curved panel, stay rectangular. [Rendering](../dev/rendering.md#rounded-scene-geometry) states the rules.

## Theme fields

`lua/lunette-contracts/theme.luau` declares the fields and `lua/lunette-plugins/theme/descriptors.luau` validates them. The values are in `theme/base.luau`, `theme/standard/presets.luau`, and `theme/arcade/preset.luau` under `lua/lunette-plugins/`. Each field reaches the components below unless a component option overrides it.

| Field | Consumers | Component override |
|---|---|---|
| `colors.background` | UI backing, keyboard plate, manager footer | UI `background`, keyboard `plateColor` |
| `colors.elevatedBackground` | Titlebars, manager sidebar | Titlebar `barColor` |
| `colors.foreground` | UI text, titles, keyboard legends, errors, hints, manager text | UI `foreground`, titlebar `titleColor`, keyboard `legendColor`, errors and hint `foreground` |
| `colors.mutedForeground` | Manager inactive, disabled, and secondary text | None |
| `colors.control` | UI controls, keyboard keys, manager nodes | UI `control`, keyboard `keyColor` |
| `colors.hovered` | Hovered controls and keys, titlebar highlight | UI `hovered`, keyboard `hoverColor`, titlebar `barHighlightColor` |
| `colors.pressed` | Held controls and keys | UI `pressed`, keyboard `heldColor` |
| `colors.disabled` | Disabled controls | UI `disabled` |
| `colors.border` | UI, panel, and titlebar outlines, manager node borders | UI `border`, panels and titlebar `borderColor` |
| `colors.focus` | Focus marks, carets, highlighted borders, manager selection | UI `focus`, panels and titlebar `borderHighlightColor` |
| `colors.selection` | Text selection, selected items and rows | UI `selection` |
| `colors.error` | Validation messages, failed manager states | UI `error` |
| `colors.errorBackground` | Error overlay, failed manager nodes | Errors `background` |
| `colors.success` | Active manager states | None |
| `colors.warning` | Loading, unloading, and blocked manager states | None |
| `colors.ownershipEdge`, `colors.dependencyEdge` | Manager graph relationships | None |
| `colors.pointer`, `colors.pointerHovered` | Laser beam and landing indicator | Laser `color`, `hoverColor` |
| `typography.font` | UI text, manager, titles, keyboard legends, errors, hints | Each component's `font` |
| `typography.bodySize` | UI `fontSize`, manager rows | UI `fontSize` |
| `typography.smallSize` | Manager labels, footer, and toolbar | None |
| `typography.titleHeight` | Titlebar and native chrome titles, in metres | Titlebar and panels `titleHeight` |
| `typography.keyboardLegendHeight` | Keyboard legends, in metres | Keyboard `legendHeight` |
| `typography.errorTextHeight` | Error overlay text, in metres | Errors `textHeight` |
| `typography.hintTextHeight` | Hint text, in metres | Hint `textHeight` |
| `metrics.padding`, `metrics.spacing`, `metrics.rowHeight` | UI controls and collections, manager rows | UI `padding`, `spacing`, `rowHeight` |
| `metrics.borderWidth` | UI outlines | UI `borderWidth` |
| `metrics.titlebarHeight` | Titlebar height, in metres | Titlebar `barHeight` |
| `metrics.titlebarBorderThickness` | Native chrome and titlebar outlines, in metres | Panels and titlebar `borderThickness` |
| `metrics.keyboardGap` | Gap between key faces, in metres | Keyboard `gap` |
| `radii.uiPanel` | UI panel backing, in metres | UI `panelRadius`, in logical units |
| `radii.uiControl` | UI control faces, in logical units | UI `controlRadius` |
| `radii.keyboardBacking`, `radii.keyboardKey` | Keyboard backing and keys, in metres | Keyboard `backingRadius`, `keyRadius` |
| `radii.titlebar` | Titlebar corners, in metres | Titlebar `cornerRadius` |
| `radii.window`, `radii.monitor` | Scene window and monitor content, in metres | Panels `windowRadius`, `monitorRadius` |

The manager caps some tokens in its fixed-size toolbar and editors, as [Session styling](runtime-manager.md#session-styling) lists. Theme fields do not change keyboard layout, `keyUnit`, depth offsets, haptics, panel placement, or input routing.

## Decisions

Aim smoothing runs before picking, so selection and feedback use one ray. It follows the [1 Euro filter](https://gery.casiez.net/1euro/) with separate speed gains for position and direction. The grab pose and button edges stay raw because filtering them would delay manipulation and clicks. Smoothing in each widget was rejected because every consumer would have to keep its drawn and dispatched coordinates in step.

The trigger lock acts on analog pressure before the click edge, because the controller moves during a pull. It holds the shared ray rather than per-widget coordinates, so native windows and UI panels behave alike. Coarse movement releases it until the trigger is released, which keeps dragging and avoids repeated locking.

Session controls are menu actions and UI controls, so the keyboard, reload, theme, and workspace controls work without key chords. The bindings provider stays available for custom input.

Settings are keyed by entry id and expand to one ordinary patch each, so a configuration needs no plugin imports while each plugin keeps its own failure, outage, and cleanup boundaries. Short keys were rejected because several named a `desktop/` consumer while the same id in a patch named a provider. A typed configure patch per entry was rejected because it needed the module's export shape and could name another entry's definition. A setting and a patch for the same entry are rejected rather than ordered, so each entry has one source of configuration. Patches carry structure: inserting, replacing, and disabling entries.

`desktop/workspaces` puts a placed window in no workspace into the selected one, and leaves rule and saved tags alone, because those names are configuration and saved state. Composition pointing adoption at the first workspace was rejected because only the setting did it; an equivalent patch or a Configure edit left new windows outside every workspace.

The desktop's lasers take their aim, trigger lock, style, and tuning from the `laser` and `interaction` entries alone. Per-hand options on `desktop/pointing` were rejected because they overrode the providers' options and made the same option settable in two places.
