# Shipped plugins

The shipped tree contains 46 independent plugin leaves in 18 responsibility categories. A category groups related plugins and public libraries. It has no activation entry and activates nothing. The [desktop composition](../lunette-desktop/init.luau) selects entries and startup order; a configuration can compose or replace leaves independently.

[Plugin authoring](../../docs/plugins/writing-plugins.md), the [plugin facade](../lunette-plugin/README.md), and [service contracts](../lunette-contracts/README.md) define composition and runtime access. [Desktop configuration](../../docs/users/desktop-configuration.md) defines user workflows.

## Categories

| Category | Responsibility |
| --- | --- |
| [Audio](audio/README.md) | PCM capture and shared spectral analysis. |
| [Diagnostics](diagnostics/README.md) | Error reporting, retention, and presentation. |
| [Environment](environment/README.md) | Background rendering and empty-desktop guidance. |
| [Graphics](graphics/README.md) | Caller-owned drawing mechanisms. |
| [Input](input/README.md) | Keyboard routing, virtual keyboards, and controller attachment. |
| [Interaction](interaction/README.md) | Surface offers, pointer gestures, grabs, and drops. |
| [Layout](layout/README.md) | Layout registration, arrangement, and persistence. |
| [Lifecycle](lifecycle/README.md) | Failure-complete cleanup operations. |
| [Menu](menu/README.md) | Action registration and wrist-menu presentation. |
| [Pacing](pacing/README.md) | Window-rate recommendations and application. |
| [Panels](panels/README.md) | Panel creation, rendering, decorations, and monitor mirrors. |
| [Registration](registration/README.md) | Caller-owned listeners and named values. |
| [Scale](scale/README.md) | Output-scale recommendations and application. |
| [Session](session/README.md) | Frame dispatch, session actions, and runtime management. |
| [Theme](theme/README.md) | Appearance resolution, named themes, and selection. |
| [UI](ui/README.md) | Flat VR controls and titlebar configuration. |
| [Window](window/README.md) | Rules, placement, and adoption. |
| [Workspace](workspace/README.md) | Panel tags and workspace visibility. |

## Public imports

A leaf's entry is public. Its `config` module is public where present. Other imports target only the libraries and deliberate extensions documented by the category guides. All other production modules are private to their owner. Colocation in the same category grants no private access.

An entry import exposes a plugin definition or its constructor, not its live service instance. Consumers import a [contract](../lunette-contracts/README.md) and obtain its service through `context:require`. Shared value validation belongs in [contract schemas](../lunette-contracts/schemas/README.md), without provider imports or resource acquisition.

Category libraries do not register runtime services or activate plugins. Each call receives its data, pass, callbacks, context, or owner from the caller. Resource-producing calls use the supplied context or require caller-owned cleanup. The category guides state these ownership and call-side guarantees. Imports acquire no module-level resources and remain safe across source reload.

Entry ids, contract ids, and settings keys remain separate from module paths. The `desktop/pacing` entry uses `@lunette-plugins/pacing/controller`; the `desktop/persistence` entry provides `lunette/arrangement` through `@lunette-plugins/layout/persistence`. The keyboard display keeps the entry id `desktop/keyboard` at `@lunette-plugins/input/keyboard-display`. A path change does not rename a settings patch or a service contract.

## Public entry migration

The hierarchy is a clean break. Removed paths have no forwarding modules or compatibility aliases. The previous-path column names paths relative to the plugin root, without the alias prefix. The new-path column names supported imports. Existing `config` imports follow the same move where the leaf declares a configuration module; leaves without one do not gain one. Entry ids, contract ids, settings keys, saved formats, and activation order remain unchanged.

| Previous entry path | Public entry import |
| --- | --- |
| `audio` | `@lunette-plugins/audio/capture` |
| `audio-analysis` | `@lunette-plugins/audio/analysis` |
| `errors` | `@lunette-plugins/diagnostics/error-stream` |
| `desktop/errors` | `@lunette-plugins/diagnostics/error-display` |
| `desktop/backdrop` | `@lunette-plugins/environment/backdrop` |
| `desktop/hint` | `@lunette-plugins/environment/empty-desktop-hint` |
| `bindings` | `@lunette-plugins/input/bindings` |
| `focus` | `@lunette-plugins/input/focus` |
| `desktop/input` | `@lunette-plugins/input/physical-routing` |
| `keyboard` | `@lunette-plugins/input/keyboard` |
| `keyboard-display` | `@lunette-plugins/input/keyboard-display` |
| `laser` | `@lunette-plugins/input/laser` |
| `desktop/pointing` | `@lunette-plugins/input/hand-pointers` |
| `surfaces` | `@lunette-plugins/interaction/surfaces` |
| `interaction` | `@lunette-plugins/interaction/pointers` |
| `drops` | `@lunette-plugins/interaction/drops` |
| `layouts` | `@lunette-plugins/layout/catalog` |
| `layout/arc` | `@lunette-plugins/layout/arc` |
| `desktop/arrange` | `@lunette-plugins/layout/arrange` |
| `arrangement` | `@lunette-plugins/layout/persistence` |
| `menu` | `@lunette-plugins/menu/action-registry` |
| `desktop/menu` | `@lunette-plugins/menu/wrist-menu` |
| `pacing` | `@lunette-plugins/pacing/service` |
| `desktop/pacing` | `@lunette-plugins/pacing/controller` |
| `panels` | `@lunette-plugins/panels/service` |
| `desktop/render` | `@lunette-plugins/panels/renderer` |
| `desktop/decorations` | `@lunette-plugins/panels/decorations` |
| `desktop/monitors` | `@lunette-plugins/panels/monitors` |
| `scale` | `@lunette-plugins/scale/service` |
| `desktop/scale` | `@lunette-plugins/scale/output-controller` |
| `frame` | `@lunette-plugins/session/frame` |
| `desktop/actions` | `@lunette-plugins/session/menu-actions` |
| `desktop/manager` | `@lunette-plugins/session/plugin-manager` |
| `theme` | `@lunette-plugins/theme/resolver` |
| `themes` | `@lunette-plugins/theme/catalog` |
| `theme/standard` | `@lunette-plugins/theme/standard` |
| `theme/arcade` | `@lunette-plugins/theme/arcade` |
| `desktop/theme` | `@lunette-plugins/theme/selector` |
| `ui` | `@lunette-plugins/ui/toolkit` |
| `rules` | `@lunette-plugins/window/rule-resolver` |
| `desktop/rules` | `@lunette-plugins/window/configured-rules` |
| `placement` | `@lunette-plugins/window/placement` |
| `adoption` | `@lunette-plugins/window/adoption` |
| `desktop/adoption` | `@lunette-plugins/window/adoption-controller` |
| `tags` | `@lunette-plugins/workspace/tags` |
| `desktop/workspaces` | `@lunette-plugins/workspace/controller` |

## Library, schema, and extension migration

Removed helper paths map to exact public libraries. Stable values map to neutral contract schemas. Editable author configuration remains separate from stable value validation and runtime resource creation.

| Previous path or use | Supported boundary |
| --- | --- |
| `cleanup` | `@lunette-plugins/lifecycle/cleanup` |
| `listeners` | `@lunette-plugins/registration/listeners` |
| `registry` | `@lunette-plugins/registration/registry` |
| `protected` | `@lunette-plugins/diagnostics/protected-call` |
| `desktop/logging` | `@lunette-plugins/diagnostics/desktop-logging` |
| `pass-state` | `@lunette-plugins/graphics/pass-state` |
| `client-pixels` | `@lunette-plugins/graphics/client-pixels` |
| `theme/rounded-geometry` | `@lunette-plugins/graphics/rounded-geometry` |
| `theme/drawing` | `@lunette-plugins/graphics/rounded-drawing` |
| `theme/descriptors` stable values, resolution, font keys, and equality | `@lunette-contracts/schemas/theme` |
| `theme/descriptors` editable settings and projection | `@lunette-plugins/theme/configuration` |
| `theme/frame-style` | `@lunette-contracts/schemas/frame-style` |
| `ui/titlebar-style` value validation | `@lunette-contracts/schemas/titlebar-style` |
| `ui/titlebar-style` editable settings and projection | `@lunette-plugins/ui/titlebar-configuration` |
| `rules/policy` shared value validation and field classification | `@lunette-contracts/schemas/rules` |
| `theme/base` | `@lunette-plugins/theme/base` remains public. |
| `interaction/picking` | `@lunette-plugins/interaction/picking` remains a public library. |
| `layout/arc/geometry` | `@lunette-plugins/layout/arc/geometry` remains a public extension. |
| `keyboard/draw` legend drawing | `@lunette-plugins/input/keyboard/legend` |
| `keyboard/board` hook types | `@lunette-plugins/input/keyboard/hooks` |

Only the named uses migrate to public exports. Rendering internals, rule evaluation, and other former implementation imports have no public replacement. A consumer uses a contract service or a configured callback instead of following an implementation path into its new location.
