# Standard plugins

The Lua module roots `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop` hold the plugin facade, neutral service contracts, built-in plugins, and shipped desktop composition. Every policy shipped by lunette is a Lua provider or consumer that uses the public `lunette` API. A configuration can replace or omit a plugin, or use `lunette` without loading standard plugins. [Plugin authoring](lua-api.md#plugin-authoring) and [Architecture](architecture.md#plugin-runtime) specify the plugin model and runtime.

A provider implements a named service contract. A consumer requires one or more contracts. A contributor registers a value with a provider's broker. Each plugin README beside its entry module describes its purpose, module path, desktop entry id, configuration source, and local limitations. Longer plugin specifications live in subject-named files under that plugin's `docs/` directory. Shared connections and the shipped composition are recorded here. Contract modules own service types and versions. Each plugin's `config.luau` or descriptor owns its schema and defaults.

## Contracts and providers

The shipped composition includes these providers. `Requires` lists service contracts, not Lua module imports. A plugin remains inactive while a required provider is unavailable.

| Entry id | Plugin README | Provides | Requires |
|---|---|---|---|
| `frame` | [`frame`](../../lua/lunette-plugins/frame/README.md) | `lunette/frame` 2 | none |
| `audio` | [`audio`](../../lua/lunette-plugins/audio/README.md) | `lunette/audio` 1 | frame |
| `audio-analysis` | [`audio-analysis`](../../lua/lunette-plugins/audio-analysis/README.md) | `lunette/audio-analysis` 1 | frame, audio |
| `theme` | [`theme`](../../lua/lunette-plugins/theme/README.md) | `lunette/theme` 1 | none |
| `themes` | [`themes`](../../lua/lunette-plugins/themes/README.md) | `lunette/themes` 1 | none |
| `surfaces` | [`surfaces`](../../lua/lunette-plugins/surfaces/README.md) | `lunette/surfaces` 1 | none |
| `panels` | [`panels`](../../lua/lunette-plugins/panels/README.md) | `lunette/panels` 3 | theme |
| `drops` | [`drops`](../../lua/lunette-plugins/drops/README.md) | `lunette/drops` 1 | none |
| `focus` | [`focus`](../../lua/lunette-plugins/focus/README.md) | `lunette/focus` 2 | frame |
| `bindings` | [`bindings`](../../lua/lunette-plugins/bindings/README.md) | `lunette/bindings` 1 | frame |
| `interaction` | [`interaction`](../../lua/lunette-plugins/interaction/README.md) | `lunette/interaction` 2 | drops, focus |
| `laser` | [`laser`](../../lua/lunette-plugins/laser/README.md) | `lunette/laser` 1 | interaction, theme |
| `keyboard` | [`keyboard`](../../lua/lunette-plugins/keyboard/README.md) | `lunette/keyboard` 3 | focus, theme |
| `ui` | [`ui`](../../lua/lunette-plugins/ui/README.md) | `lunette/ui` 3 | focus, surfaces, theme, frame |
| `menu` | [`menu`](../../lua/lunette-plugins/menu/README.md) | `lunette/menu` 1 | none |
| `tags` | [`tags`](../../lua/lunette-plugins/tags/README.md) | `lunette/tags` 1 | none |
| `rules` | [`rules`](../../lua/lunette-plugins/rules/README.md) | `lunette/rules` 1 | none |
| `placement` | [`placement`](../../lua/lunette-plugins/placement/README.md) | `lunette/placement` 1 | panels, rules, tags |
| `adoption` | [`adoption`](../../lua/lunette-plugins/adoption/README.md) | `lunette/adoption` 1 | panels, placement, rules |
| `layouts` | [`layouts`](../../lua/lunette-plugins/layouts/README.md) | `lunette/layouts` 1 | none |
| `errors` | [`errors`](../../lua/lunette-plugins/errors/README.md) | `lunette/errors` 1 | none |
| `pacing` | [`pacing`](../../lua/lunette-plugins/pacing/README.md) | `lunette/pacing` 1 | none |
| `scale` | [`scale`](../../lua/lunette-plugins/scale/README.md) | `lunette/scale` 1 | none |
| `desktop/keyboard` | [`keyboard display`](../../lua/lunette-plugins/keyboard-display/README.md) | `lunette/keyboard-display` 1 | frame, focus, keyboard, surfaces, ui |
| `desktop/persistence` | [`arrangement`](../../lua/lunette-plugins/arrangement/README.md) | `lunette/arrangement` 1 | drops, frame, panels, rules, tags |

The keyboard display module is `@lunette-plugins/keyboard-display`, and its entry id is `desktop/keyboard`. The arrangement module is `@lunette-plugins/arrangement`, and its entry id is `desktop/persistence`. Entry ids name settings, patches, errors, and runtime inspection.

The default composition also includes these broker contributors. They register values with providers and do not provide top-level services.

| Entry id | Plugin README | Broker |
|---|---|---|
| `layout/arc` | [`arc layout`](../../lua/lunette-plugins/layout/arc/README.md) | `lunette/layouts` |
| `theme/standard` | [`standard themes`](../../lua/lunette-plugins/theme/standard/README.md) | `lunette/themes` |
| `theme/arcade` | [`Arcade theme`](../../lua/lunette-plugins/theme/arcade/README.md) | `lunette/themes` |

## Default configuration

The shipped composition includes these consumers. A child is a separate plugin installed by its parent. Each plugin's configuration schema is the source of truth for fields, defaults, and validation.

| Entry id | Plugin README | Requires | Connection |
|---|---|---|---|
| `desktop/render` | [`panel rendering`](../../lua/lunette-plugins/desktop/render/README.md) | frame, panels | Updates and draws panels; a child offers surfaces for picking. |
| `desktop/backdrop` | [`backdrop`](../../lua/lunette-plugins/desktop/backdrop/README.md) | frame | Draws the environment; response, process-status, attention, and controls attach as separate children. |
| `desktop/hint` | [`hint`](../../lua/lunette-plugins/desktop/hint/README.md) | frame, panels, theme | Uses panels and theme while no panel exists. |
| `desktop/decorations` | [`decorations`](../../lua/lunette-plugins/desktop/decorations/README.md) | frame, panels, ui | Adds shared titlebars to native panels. |
| `desktop/pointing` | [`pointing`](../../lua/lunette-plugins/desktop/pointing/README.md) | frame, laser, surfaces | Updates lasers against offered surfaces and draws feedback. |
| `desktop/input` | [`physical input`](../../lua/lunette-plugins/desktop/input/README.md) | focus, frame | Delivers physical keys and committed text. |
| `desktop/menu` | [`wrist menu`](../../lua/lunette-plugins/desktop/menu/README.md) | ui, frame, menu | Renders the wrist menu and invokes menu actions. |
| `desktop/actions` | [`session actions`](../../lua/lunette-plugins/desktop/actions/README.md) | menu | Registers Reload; a child registers Keyboard. |
| `desktop/errors` | [`error display`](../../lua/lunette-plugins/desktop/errors/README.md) | errors, frame, theme | Displays the latest error report. |
| `desktop/workspaces` | [`workspaces`](../../lua/lunette-plugins/desktop/workspaces/README.md) | panels, placement, tags | Holds workspace tags; a child registers workspace actions. |
| `desktop/monitors` | [`monitor mirrors`](../../lua/lunette-plugins/desktop/monitors/README.md) | panels | Mirrors host monitors; its optional tags child can be unavailable without stopping mirroring. |
| `desktop/rules` | [`default rules`](../../lua/lunette-plugins/desktop/rules/README.md) | rules | Registers the desktop rule source. |
| `desktop/arrange` | [`arrangement policy`](../../lua/lunette-plugins/desktop/arrange/README.md) | drops, frame, layouts, panels, placement, tags | Connects placed panels, tags, layouts, and drops. |
| `desktop/adoption` | [`window adoption`](../../lua/lunette-plugins/desktop/adoption/README.md) | adoption | Adopts windows; a child remembers dropped poses. |
| `desktop/pacing` | [`window pacing`](../../lua/lunette-plugins/desktop/pacing/README.md) | frame, panels, pacing | Applies the pacing provider to windows and monitors. |
| `desktop/scale` | [`output scale`](../../lua/lunette-plugins/desktop/scale/README.md) | frame, panels, scale | Applies the scale provider to outputs. |
| `desktop/manager` | [`runtime plugin manager`](../../lua/lunette-plugins/desktop/manager/README.md) | composition, frame, ui, theme, menu | Provides the runtime manager panel. |
| `desktop/theme` | [`runtime theme selector`](../../lua/lunette-plugins/desktop/theme/README.md) | frame, menu, theme, themes | Selects a theme from the catalog. |

`etc/xdg/lunette/main.luau` calls `require('@lunette-desktop').run()`. `lua/lunette-desktop/init.luau` is the source of truth for the default list and its order. Each entry is `{ id, definition, config }`, where `definition` is a plugin definition or a factory that returns one. `lua/lunette-desktop/settings.luau` composes entry schemas into the typed settings table and is checked against the default entry list. The shipped desktop starts no application; the development configuration inserts a terminal plugin.

```text
configuration load
       |
       v
@lunette-desktop.compose(default entries, settings, patches)
       |
       v
frame.install(start, stop) ---- binds LÖVR callbacks once
       |
       v
lovr.load -> management.start(entries) -> plugin runtime graph
```

`desktop.compose(options)` returns the patched entry list without starting it. `desktop.run(options)` composes the list, identifies protected entries, and installs frame callbacks. The `lovr.load` callback starts the runtime. Composition runs before callbacks are bound, so a malformed patch fails while the configuration loads and safe mode reports the error.

### Entry identity, settings, and patches

Settings are keyed by entry id. Each setting becomes one ordinary configuration patch for its id. A setting and an explicit patch for the same id raise an error. Patches insert, replace, configure, or disable entries. An insertion appends by default or names an existing entry with `before` or `after`. A patch cannot reorder an existing entry. Unknown ids, duplicate patch targets, and patches that make no change raise errors. [Composition](lua-api.md#composition) specifies the generic patch rules, and [Desktop configuration](../guide/desktop-configuration.md) gives examples.

```luau
require('@lunette-desktop').run {
  settings = { ['desktop/menu'] = { hand = 'right' } },
  patches = {
    { id = 'keyboard', disabled = true },
    { insert = { id = 'my-hud', definition = hud.definition }, before = 'desktop/adoption' },
  },
}
```

One entry id names configuration, patches, errors, and runtime inspection. Short setting keys were rejected because several named a `desktop/` consumer while a patch with the same id named a provider. A typed configure patch per entry was rejected because its target would need to be found among module shapes and could name another entry's definition. Settings use a table keyed by entry id and reuse each entry's descriptor. An id-discriminated patch union was rejected because it needs an arm for inserted entries, which would accept a mistyped option for any shipped entry. A combined desktop plugin was rejected because it would require the union of its consumers' dependencies and lose independent outages.

The default sequence is the source of truth for entry order. Patches can position insertions or replace an entry under its existing id, but cannot reorder existing entries. Service dependencies determine readiness. Entry order also matters when initialization registers a value before another entry uses it, as with rule sources before adoption resolves the first window.

`desktop.run` protects these entries for recovery: `desktop/manager`, `desktop/menu`, `desktop/keyboard`, `desktop/pointing`, and `desktop/actions`. Direct mutation of the raw runtime bypasses this composition-local protection policy. Runtime management, snapshots, and ownership belong to [Architecture](architecture.md#plugin-runtime) and [Composition](lua-api.md#composition).

## Service connections and outages

The audio providers have no dependency on the backdrop, UI, panels, focus, or interaction. They open no capture until a consumer acquires a reader. Each consumer can acquire its own PCM reader and analysis profile through the neutral contracts. Disabling one visual effect does not withdraw PCM from another consumer. [Audio](audio.md#lua-providers) specifies capture and analysis behavior.

```text
lunette/audio -----> lunette/audio-analysis -----> backdrop response child
       |                                               (optional)
       +-----> backdrop process-status child           (optional)
       +-----> independent audio consumers
```

The backdrop base requires only frame. Its response child requires analysis and frame, its process-status child requires audio and frame, its attention child requires frame, panels, and surfaces, and its controls child requires frame, UI, and menu. An audio or UI outage does not remove the environment. The [backdrop plugin](../../lua/lunette-plugins/desktop/backdrop/README.md) owns its visual policy and diagnostics.

The panel renderer is the parent consumer; its optional child offers panels through surfaces. Pointing is a separate consumer that requires frame, laser, and surfaces. A surfaces outage stops picking and pointing at panels, but panel drawing continues.

```text
frame + panels -----> desktop/render -----> update and draw panels
                           |
                           +-- child: panels + surfaces -> offered surfaces
                                                          |
frame + laser + surfaces ----------------------------> desktop/pointing
                                                       update: pointing
                                                       draw: feedback
```

`desktop/keyboard` provides the keyboard-display service consumed by a child of `desktop/actions`. If the display provider is unavailable, `desktop/actions` still registers Reload. `desktop/workspaces` keeps its core behavior in the parent and registers workspace actions through an optional child. A menu outage removes those actions without changing workspace state. The [actions](../../lua/lunette-plugins/desktop/actions/README.md) and [workspaces](../../lua/lunette-plugins/desktop/workspaces/README.md) plugins specify their local behavior.

## Placement

The default placement graph uses provider entry `placement` with `rules`, `panels`, and `tags`. `desktop/rules` registers configured rules, `desktop/persistence` provides saved arrangements and registers a saved rule source, `desktop/adoption` consumes the adoption service to create placements, and `desktop/arrange` consumes placements and layouts. These entries let a configuration replace a rule source, persistence, or layout consumer independently.

```text
configured rules (100) ----+
saved arrangement (200) ----+--> rules service ----+
native lunette.pose (300) --+                    |
                                                 v
panels + tags -----------------------------> placement service
                                                 ^
                                                 |
desktop/adoption --> adoption service -----------+

interaction --> drops --> pose-memory child / persistence / arrange
layouts + tags + placement + panels ------------------> arrange
```

Rule sources apply in ascending precedence. Configured rules use `PRECEDENCE.rules` (100), saved arrangements use `PRECEDENCE.persisted` (200), and the native `lunette.pose` property uses `PRECEDENCE.native` (300). A higher-precedence source wins for a property it supplies. Rule sources must register before adoption resolves the first window, so an inserted source belongs before `desktop/adoption`. The rules contract and [placement provider](../../lua/lunette-plugins/placement/README.md) define the service boundary.

The pose-memory child of `desktop/adoption` listens to `lunette/drops`, writes a dropped window's pose as `lunette.pose`, and registers the rule source that reads it on later placement. It registers before the adoption provider resolves the first window. A provider method for the reading half was rejected because a replacement adoption provider would then carry half of the feature. The [adoption plugin](../../lua/lunette-plugins/desktop/adoption/README.md) owns pose-memory policy.

`desktop/persistence` supplies a rule source and listens to drops and quit to save state. The [arrangement provider](../../lua/lunette-plugins/arrangement/README.md) owns save timing, file format, and saved-slot behavior. `desktop/arrange` consumes drops and placements, panels, layouts, and tags. The [arrangement consumer](../../lua/lunette-plugins/desktop/arrange/README.md) owns candidate selection and layout policy. Layout options belong to the plugin that registers the layout; the [arc layout](../../lua/lunette-plugins/layout/arc/README.md) owns its tuning.

## Other shared boundaries

Rendering, mirroring, and the empty-scene hint are separate entries, so a configuration can replace one without replacing the others. Their plugin READMEs describe local behavior.

Small VR controls use the replaceable `lunette/ui` provider, so a configuration can replace control policy without importing a widget implementation. Larger interfaces remain Wayland clients. The menu action broker is separate from its wrist-menu renderer, so the renderer, UI provider, or broker can be replaced independently. Enabled and selected state are explicit owner updates, so listing does not run action code. The keyboard display observes focus metadata rather than being required by each widget, which avoids a dependency cycle. Contract behavior is specified in [The Lua API](lua-api.md#contracts).

Pointer feedback draws in its own final `feedback` phase. Raising the pointing draw order would not move it after another phase, because order applies only within a phase. Moving pointing updates after overlays would change interaction timing. [Frame dispatch](lua-api.md#frame-dispatch) specifies phase ordering.

## Pacing and scale

Pacing and scale are separate providers, and the desktop entries read the scene and apply their results. A different policy is a different provider, and a different reading of the scene is a different consumer. Both consumers are on by default and revert their changes on unload, because a disabled entry must not leave outputs at values it chose. Details belong to the [pacing](../../lua/lunette-plugins/desktop/pacing/README.md) and [scale](../../lua/lunette-plugins/desktop/scale/README.md) plugins.

## Decisions

The Lua roots stay separate from `lunette`. Distinct roots keep a Lua implementation from looking like native mechanism and let a configuration replace any provider. Contracts stay separate from providers, so plugins typecheck against a service without importing its implementation. The standard library uses only the public `lunette` API. A missing capability is an API defect, not a reason to take a private path.

A shipped plugin lives in `@lunette-plugins` whatever its role. A provider's folder follows the contract it provides, and another plugin's folder follows its entry id. `desktop/pacing` is `@lunette-plugins/desktop/pacing`. `desktop/persistence` provides `lunette/arrangement`, so its module is `@lunette-plugins/arrangement` while its entry keeps the id `desktop/persistence`. Grouping consumers by domain was rejected because the path would differ from the id. Shared helpers live beside the contract vocabulary or provider module they describe. A root of helpers would make an installed provider depend on a root an installation may lack.

Every plugin module exposes the same `definition` field, whether it contains a definition or a factory. This lets an entry refer to any plugin module the same way. The desktop root only composes plugins. Consumers composed by a fixed sequence in `main.luau` were rejected because a configuration could not reuse the desktop without copying it. Patches name what they change by stable id. Unknown ids and two patches for one id raise, because a patch that matches nothing does not do what it says.

Placement is several entries, following the integration component of section 6.5 of the Cordis paper. One policy entry was rejected because replacing layout, rules, or persistence would require copying all of it. Pose memory is one child that writes a dropped pose and registers the rule source that reads it; either half without the other loses hand-placed poses across reloads. `desktop/arrange` learns about placements from the placement contract, which carries resolved properties; `panels:onAdded` reaches panels without them.

## Known gaps

The Luau checker checks service and configuration shapes but does not prove that the plugin graph is wired correctly. The plugin runtime validates declarations, required providers, and provisions when it builds the graph. Audio acceptance remains pending as recorded in [Audio](audio.md#acceptance) and the [Roadmap](roadmap.md#known-gaps). Plugin-specific graphics, host-capture, and headset acceptance gaps remain in the plugin or native documents that own them.

## Deliberately left open

Whether static checking should validate which provider a service resolves to remains open. The checker validates local service shapes, and the runtime validates the graph's declarations and provisions.
