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

Each section reuses the corresponding plugin module's exported `Config` type. The checker rejects a wrong value such as `menu = { hand = 'rigth' }`. `desktop.compose` parses the declared settings and expands them into entry patches before activation, so an invalid settings value aborts composition. When the native runtime starts definitions directly, configuration validation occurs as each instance activates; an invalid value fails that instance without aborting other entries. Unknown settings sections fail composition before LÖVR callbacks are bound.

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

## Runtime themes

`desktop/theme` selects the runtime theme through `lunette/theme`, chooses it from the `lunette/themes` catalog, and registers actions with `lunette/menu`. `lua/lunette-plugins/desktop/theme/config.luau` owns its configuration descriptor and defaults. `preset` names a catalog theme and defaults to `dark`. `overrides` defaults to an empty object. The shipped themes are plugins: `theme/standard` registers Dark and Light, and `theme/arcade` registers Arcade. Dark uses rounded desktop controls, Light uses the same geometry with a light palette, and Arcade replaces the palette, typography, spacing, and radii. A configuration adds a theme by inserting a plugin that registers one, and removes Arcade by disabling `theme/arcade`. [Adding a theme](writing-plugins.md#adding-a-theme) shows both.

The wrist menu's Appearance group contains one `Theme: <label>` row for each registered theme, in catalog order: Theme: Dark, Theme: Light, and Theme: Arcade on the shipped desktop. Exactly one row is selected while a theme is shown. These actions update one theme registration in place. A failed update preserves the prior theme and menu selections and reports the error through the normal menu boundary. A successful update does not restart the theme provider or its consumers.

The selector shows the session's chosen theme while it is registered, then the configured theme, and otherwise holds no selection. Disabling `theme/arcade` while Arcade is chosen removes its row and shows the configured theme. Re-enabling it shows Arcade again, unless another theme was chosen in the meantime. A configured or chosen name that no plugin registers is logged once as a warning after the first frame, with the registered names.

Disabling or removing `desktop/theme` releases its theme selection and menu actions. With no other theme selection, the provider returns to its square base theme. Re-enabling or restoring the entry retains the session's chosen theme. A provider outage also retains that choice across reactivation. Reload configuration rebuilds the factory definition and resets selection to the configured preset. Menu selections are session state and are not written to the configuration or arrangement file.

The entry's Configure action in Plugins exposes `preset` as a text field and sparse `overrides`. A changed configured preset takes precedence over the current menu selection after successful activation. Applying configuration with the same preset, including an overrides-only edit, retains the current menu selection. Configuration replacement reloads this consumer through the normal manager lifecycle; it does not replace the provider. A typed patch uses the selector module's direct factory export:

```luau
local desktop = require '@lunette-desktop'
local theme = require '@lunette-plugins/desktop/theme'

local entries = desktop.compose {
  patches = {
    desktop.configure('desktop/theme', theme) {
      preset = 'light',
      overrides = { radii = { uiControl = 4 } },
    },
  },
}
```

`overrides` accepts sparse `colors`, `typography`, `metrics`, and `radii` objects. `lua/lunette-plugins/theme/descriptors.luau` owns their fields and validation. Colours are four-component RGBA arrays with values from 0 to 1. Typography dimensions and positive metrics must be greater than zero; padding, spacing, border widths, gaps, and radii may be zero. The selector resolves the chosen complete theme with these overrides before passing it to the public theme service.

The editable `overrides.typography.font` is an object with a `kind` choice and optional `file`, `size`, and `spread` fields. `{ kind = 'default' }` rejects those optional fields. `{ kind = 'file', file = 'fonts/example.ttf' }` requires a non-empty path and projects omitted `size` and `spread` to 32 and 4. Supplied size and spread must be positive. Plugins can traverse and edit these fields; Apply validates the whole font object. The public `ThemeOverrides` contract remains strict: a file font passed directly to the service supplies its file, size, and spread.

A missing font file fails selector activation without publishing that theme. The theme provider remains active and returns to the base theme when no other selection remains. A failed configuration replacement uses the manager's existing recovery path. Recover reapplies the last active configuration; it does not retain the failed configuration's theme or change configuration replacement into a transaction. A missing font during a menu selection leaves the existing registration, chosen theme, and menu selections unchanged.

## Theme acceptance workflows

The operator performs the named workflows below. Broker logic, native font use, and headset appearance remain separate pending gates until observations are recorded. Type checks, installed-asset byte comparisons, and geometry or draw recorders do not establish GPU font rendering, alpha, depth, stereo presentation, or controller ergonomics. The [theme contract](../dev/lua-api.md#runtime-themes) defines resource and notification rules; the [UI guide](ui.md#themes-and-drawing-hooks) defines hook safety and retained appearance.

### theme-broker-lifecycle

The checked [UI configuration](../../examples/ui/main.luau) includes `example/ui/theme-registration`. Its composition entry is active, but its `enabled` configuration defaults to `false`. In that state the initializer acquires no observation panel, actions, selections, listeners, reader leases, or child instances. Entry Enable changes runtime intent only and does not activate the demonstration while the configuration remains false.

The operator starts that configuration with `lunette --config-path examples/ui`, opens Plugins, selects `example/ui/theme-registration`, selects Configure, sets `enabled = true`, and selects Apply. This normal configuration replacement activates the demonstration. The wrist action Open theme lifecycle observation opens its panel. The panel's list selects a numbered action, and Run selected action invokes it. The same actions appear in the wrist menu's Theme lifecycle group. Close observation hides the panel without ending its resources.

Before base comparisons, the operator selects `desktop/theme` in Plugins and selects Disable. No other custom theme selection may remain for a base comparison. The theme provider stays enabled for the UI and recovery path. The observation panel shows the current revision, background, selected registration metadata, registration/listener/reader/invocation counts, child states, and recent action logs. The log retains only 12 lines, so observations and errors are recorded between actions. The existing error presentation and Plugins diagnostics carry reports from the ordinary menu, listener, and frame boundaries; the panel does not replace report history. Absolute revision numbers depend on prior session actions. Comparisons use the revision before and after each action.

[selections.luau](../../examples/ui/theme-registration/selections.luau), [fonts.luau](../../examples/ui/theme-registration/fonts.luau), and [session.luau](../../examples/ui/theme-registration/session.luau) own the action labels, preconditions, and checks. The ordered workflow is:

| Actions | Operation and expected observation |
|---|---|
| 1. Select A; 2. Mutate A input | A supplies background `{ 0.12, 0.04, 0.07, 1 }`. Mutating the caller's array and replacing it leaves the detached frozen snapshot and revision unchanged. |
| 3. Write frozen snapshot (error) | The frozen write raises its original error. A remains unchanged. |
| 4. Select B; 5. Update inactive A to A2 | B supplies background `{ 0.04, 0.08, 0.24, 1 }`. A's update to `{ 0.04, 0.18, 0.08, 1 }` preserves insertion rank and does not change B or the current revision. |
| 6. Unknown B key (error); 7. Invalid B color (error); 8. Missing B font (error) | Each live update raises through the menu boundary. B's snapshot, revision, rank, and font metadata remain unchanged. A missing file is an acquisition failure, distinct from validation errors. |
| 9. Dispose B; reveal A2; 10. Dispose A; restore prior/base | B disposal reveals A2. A disposal restores the preceding complete theme, which is base when the selector and other selections are absent. |
| 11. Repeat dispose; end A/B owners; 12. Update disposed B (error) | Repeated disposal and child-owner teardown are harmless. Updating disposed B raises without changing the current snapshot or revision. |
| 13. Arm one-shot reentrant listeners; 14. Trigger L1 (listener error) | L1 removes L2, adds L4, updates the selection twice, creates and ends a temporary selection owner, then raises `theme registration example: L1 deliberate listener error`. Delivery remains nonrecursive. L2 receives nothing. Independent L3 receives the first captured event despite L1's error, then the latest pending revision. L4 receives only that pending round. Event/current revision labels expose coalescing of intermediate revisions. Action 14 can complete while the separate listener error is reported. |
| 15. Disarm listeners | Listener and selection children end, the prior/base theme returns, and the log summarizes L1/L2/L3/L4 deliveries. The mutator is disarmed before the font workflow. |
| 16. Select file font; 17. Acquire distinct file reader | The example selects the mounted Space Mono file at size 37 and spread 4, then acquires an independent reader under another child owner. Its measured width and height remain positive. Size 37 distinguishes this face from Arcade's size 32 cache entry. |
| 18. Failed reader refresh (error); 19. Dispose file selection; measure reader | Failed missing-file acquisition retains the old reader. Action 18's post-error check also disposes the selection. Action 19 repeats that disposal, confirms prior/base restoration, and measures the still-live reader. Inspection retains the reader's file specification while it outlives the selection. |
| 20. Replace reader with default; inspect; 21. End file reader and selection owners | A successful default acquisition precedes disposal of the old lease. Reader metadata becomes `font=default`. Ending both child owners removes that reader lease, and its invocation count is zero. Default leases owned by ordinary UI consumers can remain. |
| 22. Acquire file reader for owner ending; 23. End reader inside withFont | The callback enters with a live reader and one invocation. Public child `Instance:disable()` ends the reader effect during the callback. Inspection then reports the reader as not live with one invocation, and the supplied Font still measures successfully. After unwind the reader hold disappears and the invocation count is zero. |
| 24. Enter ended reader (error); 25. Repeat owner ending with error | The disposed lease rejects entry before its callback runs. Action 25 acquires a fresh reader, disables its child inside `withFont`, measures the supplied Font, then raises `theme registration example: reader owner-ending error`. The original report remains visible, and unwind leaves no retired reader hold. |
| 26. Arm UI font swap | The next visible probe draw captures `visual.theme.font`, switches the live selection from file to default, and measures the old face before returning. Calling `base` with the old visual cannot submit stale geometry after the revision change. The old face stays valid through hook unwind. The operator waits for the log `Next draw succeeds with live font` before action 27. |
| 27. Arm UI font swap with draw error | The next probe draw repeats the swap, changes pass transform and colour, then raises `theme registration example: draw hook original error`. The frame boundary reports that original error. Invocation counts return to zero after unwind. The operator waits for `Next draw succeeds with live font` and checks that the probe and observation panel remain in place with normal colour and drawing. Pass restoration and visible rendering remain manual observations. |
| 28. Close probe and restore preceding theme | The probe is destroyed, reader and selection owners end, the preceding theme returns, and no invocation hold remains. |

During owner ending, the action logs record the synchronous inspection checks; no controller action can pause inside `withFont`. Plugins inspection of the theme provider shows data-only `theme.select`, `theme.onChanged`, and `theme.acquireFont` registrations. A disposed reader with an active invocation remains inspectable as `live = false` with its font specification and invocation count until unwind. Post-action inspection must no longer retain that reader hold. The check concerns the retired size-37 face and its reader, not an empty global font cache or disappearance of all UI leases. The draw actions record old-font measurement, guarded `base` continuation, original error propagation, zero post-unwind invocation counts, and a later successful draw; they do not inspect submitted GPU commands. The numbered actions cover one-level reader-owner ending, not provider shutdown or nested `withFont` invocations. The observation panel reads its live total while drawing under its own UI font invocation, so that displayed total can be positive. Zero-after-unwind checks use the action and post-probe log entries, not an assumption that the panel's draw-time total is always zero.

For final cleanup, the operator sets the example's `enabled = false` and applies it, or uses entry Disable or Remove. Its observation panel, probe, menu actions, subscriptions, selections, leases, and child activations end with that owner. Entry Enable activates it again only if its retained configuration has `enabled = true`. The operator re-enables `desktop/theme` after the base comparisons. No step disables the protected theme provider. These observations cover selection arbitration and manual invocation-lifetime acceptance, not an automated regression suite or GPU evidence.

### theme-runtime-switch

On the normal desktop, the operator keeps a Plugins configuration draft and shared keyboard open, then uses Appearance choices through Dark -> Light -> Arcade -> Dark. Exactly one preset row is selected after each successful choice. Dark/Light preserve held captures. Arcade cancels only affected geometry captures without activation and retains drafts, focus, poses, panel and control identities, and keyboard scale.

After selecting Arcade, the operator disables and re-enables `desktop/theme`, then removes it and restores it through Catalog -> Load. Base appears when no other selection remains, all selector actions end with its owner, and Arcade returns within the same session. A changed configured preset takes precedence after successful activation. An overrides-only edit with the same configured preset retains the session choice. Reload configuration resets it to configuration. With Arcade chosen, the operator disables `theme/arcade`: its row disappears and the configured theme appears. Re-enabling it restores Arcade; choosing Light first and then re-enabling it keeps Light. A failed live preset/font update through the example preserves the prior registration and revision; a failed menu choice also preserves menu selections. Preset choices update in place without reconstructing providers or widgets. Configure/Apply uses normal consumer replacement instead.

### theme-appearance-matrix

The operator compares Dark, Light, and Arcade across native window and mirror headings/actions, an explicit `chrome = true` native title, compact and expanded menus, Plugins Entries/Graph/Configure/sidebar/diagnostics, keyboard backing/keys/legends/hover/held states, errors, hints, and pointer feedback. Normal, hovered, pressed, disabled, focused, selected, active, blocked, failed, and diagnostic states remain distinguishable. Captured application pixels and application-owned widgets do not change colour.

Each field in the [field-to-consumer checklist](#theme-field-to-consumer-checklist) receives a recorded observation or a named explicit override. Arcade changes the font, text dimensions, padding, spacing, row height, border widths, radii, and semantic/state colours. Larger shared metrics remain visible in general manager rows/details and roomy UI. Configure, Apply, Enable, Recover, Remove, graph toolbar labels, editor values, and full scrollable descriptions remain readable at the default manager canvas and its unchanged 800x472 logical minimum. Toolbar and field dimensions do not enlarge to accommodate Arcade. Join, clip, and capture checks include Arcade's larger dimensions and scene monitor radius.

### theme-font-fit

In Plugins -> `desktop/theme` -> Configure, the operator enables optional `overrides.typography.font`. Its initial editable value is `{ kind = 'default' }`. The editor exposes the kind choice and optional file, size, and spread fields. The operator selects file, enters a nonempty VFS path with the shared keyboard, optionally sets positive size/spread, and applies the complete draft. Omitted file-font size/spread project to 32/4; direct public file specifications require both values. Default kind rejects file/size/spread. File kind rejects an absent or empty path, and supplied nonpositive values fail validation. Contradictory drafts remain editable and do not replace the active configuration. Disabling optional size/spread uses file defaults; unsetting the whole font override inherits the preset. Returning to default kind requires unsetting file/size/spread before Apply.

The operator checks draw and measurement agreement for fields/carets/selections, manager wrapping and compact controls, shared headings, explicit native chrome, and keyboard legends. Manager toolbars and text/boolean/choice values remain usable at default and 800x472 canvas sizes. A syntactically valid missing-file replacement ends the old selector activation, fails the new entry, and reveals another selection or base. Recover retries the last configuration observed active. If that configuration's file is also missing, Recover can fail again; restoring the asset or applying a valid/default configuration is required. Configuration replacement is not transactional. The public example's invalid live update instead leaves its live registration unchanged.

Dark and Light use the borrowed default face. Arcade uses `{ kind = 'file', file = '@lunette-plugins/theme/arcade/fonts/SpaceMono-Regular.ttf', size = 32, spread = 4 }`. The `@lunette-plugins` prefix here is a LÖVR VFS mount path, not require alias resolution. The [install manifest](../../crates/lunette/src/aliases.rs) installs the font and `OFL.txt` under `$PREFIX/share/lunette/lua/lunette-plugins/theme/arcade/fonts/`; [session boot](../../crates/lunette/src/boot.rs) mounts that root before configuration execution. The operator selects Arcade in a development session and a session installed to an isolated prefix using the [installation commands](../dev/build-and-development.md#where-things-live-at-runtime). Observations record the prefix, mounted path, native acquisition result, readable fit, and return to default. Module loading and byte-identical installed assets do not establish mounted native Font loading. Installation and session launch remain operator work.

### Theme field-to-consumer checklist

`lua/lunette-contracts/theme.luau` and [descriptors.luau](../../lua/lunette-plugins/theme/descriptors.luau) own the exact fields and validation. [base.luau](../../lua/lunette-plugins/theme/base.luau), [standard/presets.luau](../../lua/lunette-plugins/theme/standard/presets.luau), and [arcade/preset.luau](../../lua/lunette-plugins/theme/arcade/preset.luau) own the theme values. Each row is an acceptance subject, not a completed visual result. Colours are RGBA arrays in [0,1]. Font paths are nonempty VFS paths, with positive file size/spread. Other dimensions are finite; text sizes, row height, and titlebar height are positive, while padding, spacing, borders, gaps, and radii permit zero.

The table uses component paths relative to `lua/lunette-plugins/`. [ui/theme.luau](../../lua/lunette-plugins/ui/theme.luau) maps global fields to UI overrides; [ui/draw.luau](../../lua/lunette-plugins/ui/draw.luau) renders controls, text, outlines, and states. [ui/appearance.luau](../../lua/lunette-plugins/ui/appearance.luau) refreshes retained panels and converts metre radii using each world-scale axis. [ui/titlebar-style.luau](../../lua/lunette-plugins/ui/titlebar-style.luau) resolves shared headers. [keyboard/appearance.luau](../../lua/lunette-plugins/keyboard/appearance.luau), [panels/appearance.luau](../../lua/lunette-plugins/panels/appearance.luau), and [laser/style.luau](../../lua/lunette-plugins/laser/style.luau) resolve those components. [desktop/manager/draw.luau](../../lua/lunette-plugins/desktop/manager/draw.luau) renders semantic graph/sidebar appearance; [desktop/manager/widgets.luau](../../lua/lunette-plugins/desktop/manager/widgets.luau) derives retained compact overrides. [desktop/errors/init.luau](../../lua/lunette-plugins/desktop/errors/init.luau) and [desktop/hint/init.luau](../../lua/lunette-plugins/desktop/hint/init.luau) resolve their presentation.

| Exact field | Consumer and acceptance subject | Explicit override or limit |
|---|---|---|
| `colors.background` | UI backing, keyboard plate, and manager footer. Compare owned backings under all presets. | UI `background` and keyboard `plateColor` override inheritance. Application pixels remain unchanged. |
| `colors.elevatedBackground` | Shared titlebar `barColor` and manager sidebar backing. | Provider/per-titlebar `barColor` overrides the header. |
| `colors.foreground` | UI text, shared/native title text, keyboard legends, errors, hints, and manager text. | UI `foreground`, title `titleColor`, keyboard `legendColor`, and error/hint `foreground` remain explicit layers. |
| `colors.mutedForeground` | Manager inactive/removed/disabled status text, read-only rows, graph notices, and footer. | An explicit UI foreground affects ordinary manager text, not this semantic status token. |
| `colors.control` | Normal UI controls, keyboard keys, and manager graph nodes/rows. | UI `control` and keyboard `keyColor` override inheritance. |
| `colors.hovered` | Hovered UI controls, keyboard keys, and shared header highlight. | UI `hovered`, keyboard `hoverColor`, and titlebar `barHighlightColor` override inheritance. |
| `colors.pressed` | Held UI controls and keyboard keys. | UI `pressed` and keyboard `heldColor` override inheritance. |
| `colors.disabled` | Disabled UI control faces, including unavailable manager actions. | UI `disabled` overrides inheritance; graph disabled text uses `mutedForeground`. |
| `colors.border` | UI outlines and disabled legends, native panel outlines, shared header outlines, and manager node borders. | UI `border`, panels/titlebar `borderColor` override inheritance. A joined header governs the complete outline. |
| `colors.focus` | UI focus/caret/overflow marks, highlighted native/header borders, and manager selection outlines. | UI `focus`, panels/titlebar `borderHighlightColor` override inheritance. |
| `colors.selection` | UI text selection and selected collection items, plus manager selected rows. | UI `selection` overrides inheritance. Graph selection outlines use `focus`. |
| `colors.error` | UI validation messages/outlines and manager failed/quarantined graph status text. | UI `error` overrides validation drawing; error-overlay text uses `foreground`. |
| `colors.errorBackground` | Error-overlay backing and failed/quarantined manager node backing. | Errors `background` remains explicit with its existing permissive four-number validation. |
| `colors.success` | Manager active-state text through `draw.nodeColor`. | Graph lifecycle semantics remain independent of ordinary UI text overrides. |
| `colors.warning` | Manager blocked/loading/unloading text and toolbar overflow notice. | Graph lifecycle semantics remain independent of ordinary UI text overrides. |
| `colors.ownershipEdge` | Unselected manager ownership relationships. | Selected graph edges use resolved UI `focus`. |
| `colors.dependencyEdge` | Unselected manager dependency relationships. | Selected graph edges use resolved UI `focus`. |
| `colors.pointer` | Laser beam/landing feedback in its normal state. | Provider/per-laser `color` overrides inheritance; filters, length, cursor size, and haptics do not change. |
| `colors.pointerHovered` | Laser feedback while hovering a target. | Provider/per-laser `hoverColor` overrides inheritance; feedback phase and trigger lock do not change. |
| `typography.font` | Leased UI drawing/carets/selections, manager wrapping, shared/native chrome titles, keyboard legends, errors, and hints. Check the same face in drawing and measurement. | Component font specifications override inheritance. The public form's custom preview deliberately uses the default Font and fixed text colour; its controls and the separate font probe follow their resolved face. |
| `typography.bodySize` | Logical UI `fontSize` and manager inspection/row text. | The manager's 34-unit fields and 102-unit choice editor cap it at 20. Explicit UI `fontSize` remains an override. |
| `typography.smallSize` | Logical manager relationship labels, footer, secondary text, and toolbar labels. | The 26-unit toolbar caps it at 16; general secondary text retains the token. |
| `typography.titleHeight` | Metre shared-titlebar and native `chrome = true` title height. | Provider/per-titlebar and panels `titleHeight` override inheritance. |
| `typography.keyboardLegendHeight` | Metre keyboard legend height through `appearance.resolve` and `appearance.scaled`. | Keyboard `legendHeight` overrides inheritance. Existing board scale multiplies the resolved height. |
| `typography.errorTextHeight` | Metre error-overlay text height. | Errors `textHeight` overrides inheritance; report layout and line limits remain unchanged. |
| `typography.hintTextHeight` | Metre empty-scene hint text height. | Hint `size` overrides inheritance; text and position remain unchanged. |
| `metrics.padding` | Logical UI text/caret inset and collection viewport; roomy controls show Arcade's larger padding. | Toolbar uses `min(padding, 3)`; fields and choices use `min(padding, 5)`. Custom manager region insets remain structural. |
| `metrics.spacing` | Logical UI collection stride and manager general row/configuration spacing. | Choices use `min(spacing, 6)`; toolbar gaps remain structural. |
| `metrics.borderWidth` | Logical UI backing/control outline width, including shared manager controls. | UI `borderWidth` overrides inheritance. Width clamps to bounds; focus/error outlines retain a minimum of 2 logical units. Native/header outlines use `titlebarBorderThickness`. |
| `metrics.rowHeight` | Logical UI collection rows and general manager entry/catalog/configuration rows. | The choice editor uses `min(rowHeight, 40)`; fixed toolbar/field heights and caller bounds remain unchanged. |
| `metrics.titlebarHeight` | Metre shared header height and proportional action dimensions. | Provider/per-titlebar `barHeight` overrides inheritance. Joined margin is zero; separate margin remains placement policy. |
| `metrics.titlebarBorderThickness` | Metre native chrome and shared/joined outline thickness. | Panels/titlebar `borderThickness` overrides inheritance. A joined header supersedes the body outline override. |
| `metrics.keyboardGap` | Metre visible key-face gap. | Keyboard `gap` overrides inheritance and is multiplied by retained board scale. `keyUnit`, rows, layers, and rectangular key targets do not change. |
| `radii.uiPanel` | Metre UI backing silhouette, safe content clip, and initial perimeter hit. | UI `panelRadius` overrides use logical units. Inherited radius converts independently along actual x/y world scale; declared dimensions remain unchanged. |
| `radii.uiControl` | Logical UI control faces, outlines, and text-safe bounds, including manager controls. | UI `controlRadius` overrides inheritance and clamps to bounds. Control targets remain rectangular within the panel content clip. |
| `radii.keyboardBacking` | Metre keyboard backing silhouette. | Keyboard `backingRadius` overrides inheritance and follows retained scale. Board and key-unit hit targets remain rectangular; layout and `keyUnit` do not change. |
| `radii.keyboardKey` | Metre keyboard key faces. | Keyboard `keyRadius` overrides inheritance and follows retained scale. Declared key-unit hit targets remain rectangular. |
| `radii.titlebar` | Metre header top corners when joined, or all header corners when separate, plus action/grab cutouts. | Provider/per-titlebar `cornerRadius` overrides inheritance. Top radii clamp to the header height, independently of body radii. |
| `radii.window` | Metre scene window content silhouette, UV-preserving mesh, and initial hit perimeter. | Provider/panel `windowRadius` overrides inheritance; explicit zero restores square scene geometry. Granted layer content and hits stay rectangular. |
| `radii.monitor` | Metre scene monitor content silhouette and transformed UV/hit agreement. | Base/Dark/Light are zero; Arcade is 0.012 m. Provider/panel `monitorRadius = 0` restores square content independently of rounded header tops. |

[Runtime manager session styling](runtime-manager.md#session-styling) records the compact limits. Each limit takes the smaller of the resolved token and its bound. Toolbar buttons remain 26 logical units high, fields remain 34, and the choice container remains 102. The manager's 800x472 minimum, structural toolbar layout, panel dimensions, and logical scale remain unchanged. Font, colours, border width, and bounds-clamped radii still inherit in compact controls. Palette-only updates do not call cancelling style setters. Keyboard `keyUnit`, rows, layers, and `setSize` scale remain unchanged; theme-derived gap, legends, and radii use that scale. Depth offsets, haptics, panel placement, pointer filtering, and input routing are not theme fields.

### theme-documentation-check

The review checks the following subjects against current declarations, resolvers, and the checked examples:

- The [theme contract](../dev/lua-api.md#runtime-themes): exact fields, units, validation, detached immutable snapshots, complete-selection precedence, replacement updates, rank, revisions, disposal, reentrant delivery, and data-only inspection.
- [Desktop runtime themes](#runtime-themes) and `theme-runtime-switch`: entry/action ids, Dark/Light/Arcade transitions, catalog-following choices and the `theme/arcade` disable/enable fallback, session-only menu selection, changed configured preset, overrides-only edits, source reload, and selector disable/remove/restore behavior.
- `theme-broker-lifecycle`: the installed active-but-inert example, Configure -> enabled=true -> Apply, all 28 labels and preconditions, original reports, retired reader/invocation observations, and cleanup through public services and child instances.
- `theme-font-fit`, [module roots](../dev/stdlib.md#module-roots), and the install manifest: strict public FontSpec versus editable configuration, defaults and contradictory fields, live-update preservation versus failed replacement/Recover, bundled asset/licence paths, and pending development/installed native loading.
- The field checklist and [manager styling](runtime-manager.md#session-styling): every exact field, resolver/consumer, semantic lifecycle colour, bounded compact override, unchanged 800x472 structural minimum, and unchanged keyboard layout/keyUnit/scale.
- [UI hooks](ui.md#themes-and-drawing-hooks), [window rendering](#window-rendering), and [frame attachments](../dev/lua-api.md#joined-frame-attachments): sparse provider/object/control precedence, zero/nil inheritance, leases/invocation holds, retained drafts/captures, clips, draw/hit agreement, joined seams, independent header/body profiles, and layer/curved/monitor exceptions.
- [Writing plugins](writing-plugins.md#runtime-theme-selections): neutral versus UI-specific theme vocabulary, public registration signatures, owner cleanup, mounted font paths rather than require aliases, and no required custom rounding hook.

The review also checks local links, current theme terminology and capability versions, readable configuration excerpts, and explicit separation of logic checks from pending native font and GPU/headset gates. A reviewed checklist is documentation evidence only; it does not complete the manual workflows.

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

`plugin.configure(id, target)(config)` makes a typed configuration patch for an actual entry id. The target is a definition or definition factory that supplies the configuration type. The helper never invokes a factory. The desktop exports the same helper as `desktop.configure`.

```luau
local desktop = require '@lunette-desktop'
local persistence = require '@lunette-plugins/arrangement'

local entries = desktop.compose {
  patches = {
    desktop.configure('desktop/persistence', persistence.factory) { file = 'desktop.state' },
  },
}
```

The supplied id may differ from the definition's name. The patch only carries the id and configuration; it does not replace the definition. A factory still runs once per runtime start, and its returned definition survives provider outages within that runtime. Separate starts construct fresh definitions.

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

The built-in panels provider draws windows and monitor mirrors in the scene by default. This allows scene depth and session controls to cover window content. A typed patch `desktop.configure('panels', require('@lunette-plugins/panels').definition) { rendering = 'layer' }` opts windows into backend-owned composition layers. Those layers can produce sharper text, but the backend composites them after the scene, without its depth ordering. A window falls back to scene rendering while its layer claim is not granted. Monitor mirrors remain in the scene in either mode.

Scene-rendered content rounds according to the effective window or monitor radius. A clipped mesh preserves source-local pixel mapping, then applies monitor rotation and flip. Curved scene content follows the cylinder instead of flattening its clipped contour. The same emitted perimeter controls initial hits, and cutouts contain no content or depth-writing outline geometry. Native pointer motion stops on a miss, while a release still reaches the original pressed sink; rounding adds no native capture projection. Base, Dark, and Light keep monitor content square. Arcade explicitly uses a 0.012 m monitor radius. Setting `overrides.radii.monitor = 0` on `desktop/theme`, or an explicit provider or panel `monitorRadius = 0`, restores square scene content and rectangular hits.

Flat headed scene windows and monitor mirrors join their shared titlebar and content. Only the titlebar's top outer corners and the body's bottom outer corners round. The meeting edges are square, with zero gap and one outer ring. Header and body radii remain independent; a square monitor body can retain a rounded header top. The header's border thickness, depth, and normal or highlighted colour govern the whole joined outline, including native panels with `chrome = false`. Hovered and held action faces stay inside the header silhouette. Its corner cutouts cannot receive invisible actions or grabs. Removing or hiding the heading restores the body's own all-corner profile and outline.

A granted backend-owned composition layer retains square content and rectangular hits under every preset. Radius changes neither alter claims nor force fallback into the scene. A window whose claim is not granted uses its rounded scene profile. A curved body retains a separate flat titlebar even though its scene content rounds independently. Decorations do not imply clipped layer pixels or a continuous curved frame. [Rendering](../dev/rendering.md#rounded-scene-geometry) states these limits.

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

The operator performs the following named theme checks. Their observations remain pending; geometry and draw recorders do not complete them.

- `theme-rounded-content`: the operator inspects flat and curved windows and transformed or portrait monitors under Dark and Arcade, explicit zero, and custom radii. A checkerboard behind corner cutouts remains visible. Corner and straight-edge hits match visible content without stretched pixels, missing centre pixels, or phantom depth. Native releases stay paired. Arcade scene monitors trim corners; explicit zero restores square pixels and hits.
- `theme-joined-frame`: the operator inspects flat windows and mirrors from several angles and during resizing. Header top corners and independent body bottom corners meet at a square, exact, gap-free seam with one outline. Header border overrides and highlight govern the complete outline, including `chrome = false`. The rightmost action remains clipped while hovered or held. Top cutouts miss grabs and actions; adjacent visible faces retain owning grabs and actions. Descriptions agree with the safe clip. Heading hide or removal restores the ordinary body.
- `theme-widget-edges`: the operator inspects controls and custom graph or sidebar regions near rounded edges during selection, scrolling, and held input. Content-safe clips, descriptions, and rectangular control hits agree. Overflow remains visible without striping or painter instability. Accepted millimetre-range intersections retain their documented limit.
- `theme-rendering-exceptions`: the operator verifies that granted layers remain square with rectangular hits under Dark, Light, and Arcade, without radius-driven claim churn or fallback. Base, Dark, and Light monitor bodies stay square. Arcade scene monitors round, and explicit zero restores square bodies with independently rounded header tops. Curved headings remain separate.
- [theme-runtime-switch](#theme-runtime-switch) and [theme-appearance-matrix](#theme-appearance-matrix): the operator records controller preset/lifecycle behavior and every field's visible consumer or explicit override, including compact manager limits.

The [theme acceptance workflows](#theme-acceptance-workflows) also record theme-broker-lifecycle for arbitration, reentrant delivery, and owner-ending invocation lifetimes, theme-font-fit for development and installed native fonts/editing/recovery, and theme-documentation-check for current declarations and examples. Neither native font nor appearance gates are completed by mesh recorders or byte-identical installed assets. [Runtime themes](../dev/stdlib.md#runtime-themes) states those resource rules.

Logic-headless tests do not establish these visual, timing, or comfort results.

## Known gaps

The manager exposes search and configuration fields through the shared UI controls and shared keyboard. `toggleKey` is removed; the manager configuration schema reports a migration diagnostic for configurations that still set it. Logic-headless behavior does not establish XR or GPU-backed behavior, host-desktop acceptance, or installed-session execution. Manual headset acceptance remains open for readability, controller ergonomics, shaping, bidirectional editing, and IME behavior.

## Decisions

Aim smoothing runs before picking so surface selection and rendered feedback use one ray. The adaptive low-pass follows the [1 Euro filter](https://gery.casiez.net/1euro/) approach with separate vector-speed gains for position and direction. It keeps the raw grab pose and button edges because filtering those would delay manipulation and clicks. Per-widget cursor smoothing would require each consumer to keep its rendering and dispatched coordinates synchronized. The shared provider avoids that duplication. The default gains require headset tuning; logic checks do not establish comfort.

The trigger lock uses analog pressure before the digital click edge because controller movement during a pull can move the cursor off a small control. It holds the shared ray rather than individual widget coordinates so native windows and UI panels behave alike. Coarse movement disables the lock until release to preserve dragging and avoid repeated locks. The thresholds require headset tuning.

Headed desktop panels use one opt-in titlebar implementation from the UI provider. Consumers supply the title, close callback, and extra actions rather than reconstructing the drawing and input controls. This keeps heading style and close behavior consistent while preserving each consumer's visibility and native close semantics. The optional target-owned attachment supplies only header outline style and joining eligibility, without adding a general container API. Scene meshes and conservative content clips avoid stencil and offscreen requirements, retain caller bounds and ergonomic rectangular control targets, and leave hook clipping cooperative. Granted layers remain square to preserve raw-copy sharpness and claims; flat headings over curved content stay separate because a continuous curved header is outside this relationship. Native motion and original-sink release pairing stay unchanged rather than adding capture projection.

The manager uses scene depth rather than overlay painting because it is a movable panel. Opaque shared UI backing and outline geometry writes depth; rounded cutouts contain no depth-writing geometry. Controls, their contents, and glyphs occupy successive 1 mm rendering offsets without writing depth. The offsets follow drawing nesting rather than the number of sibling controls. This avoids coplanar depth conflicts, keeps transparent glyph bounds out of the depth buffer, and preserves the control order. Intersecting or nearly coincident panels can show draw-order-dependent details within the 3 mm span from the backing to its glyphs. This limited overlap is accepted rather than adding per-panel visibility masks. Pointer feedback remains a final overlay so its landing indicator is visible.

The wrist menu uses UI controls and menu actions so the shipped keyboard, reload, and workspace controls do not require physical key chords. The neutral bindings provider remains available for custom inputs. Keyboard placement stays in `wristKeyboard` for configurations that change the shared display without changing wrist geometry.

Settings expand to the existing stable-id patches so common configuration needs fewer imports without changing plugin failure, outage, or cleanup boundaries. The default retains its providers, consumers, and per-start factories.

Shorthand and raw patches cannot configure one entry together. Rejecting the collision avoids order-dependent overrides and keeps the advanced composition rule that each entry has one patch source.

Workspace expansion coordinates the initial holder and adoption defaults and runs the visibility consumer before adoption. It does not migrate explicit or persisted tags because those names are configuration and saved state, not aliases for the initial workspace.
