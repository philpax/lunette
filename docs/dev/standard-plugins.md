# Standard plugins

The shipped desktop composes replaceable plugins. [Desktop configuration](../guide/desktop-configuration.md) shows settings and patches; the [entry list](../../lua/lunette-desktop/init.luau) defines the composition and order. [The plugin facade](../../lua/lunette-plugin/README.md) specifies the shared runtime rules.

## Contracts and providers

Plugin READMEs describe use and configuration. Service declarations live in [the contracts](../../lua/lunette-contracts).

| Area | Providers | Desktop consumers and contributors |
|---|---|---|
| Dispatch and input | [frame](../../lua/lunette-plugins/frame/README.md), [focus](../../lua/lunette-plugins/focus/README.md), [bindings](../../lua/lunette-plugins/bindings/README.md) | [physical input](../../lua/lunette-plugins/desktop/input/README.md) |
| Pointing | [surfaces](../../lua/lunette-plugins/surfaces/README.md), [interaction](../../lua/lunette-plugins/interaction/README.md), [laser](../../lua/lunette-plugins/laser/README.md), [drops](../../lua/lunette-plugins/drops/README.md) | [pointing](../../lua/lunette-plugins/desktop/pointing/README.md) |
| Panels | [panels](../../lua/lunette-plugins/panels/README.md) | [rendering](../../lua/lunette-plugins/desktop/render/README.md), [decorations](../../lua/lunette-plugins/desktop/decorations/README.md), [monitor mirrors](../../lua/lunette-plugins/desktop/monitors/README.md), [empty-scene hint](../../lua/lunette-plugins/desktop/hint/README.md) |
| Appearance | [theme](../../lua/lunette-plugins/theme/README.md), [themes](../../lua/lunette-plugins/themes/README.md) | [theme selection](../../lua/lunette-plugins/desktop/theme/README.md), [standard themes](../../lua/lunette-plugins/theme/standard/README.md), [Arcade](../../lua/lunette-plugins/theme/arcade/README.md) |
| Controls | [ui](../../lua/lunette-plugins/ui/README.md), [menu](../../lua/lunette-plugins/menu/README.md) | [wrist menu](../../lua/lunette-plugins/desktop/menu/README.md), [session actions](../../lua/lunette-plugins/desktop/actions/README.md), [runtime manager](../../lua/lunette-plugins/desktop/manager/README.md) |
| Keyboard | [keyboard](../../lua/lunette-plugins/keyboard/README.md), [keyboard display](../../lua/lunette-plugins/keyboard-display/README.md) | The display uses entry id `desktop/keyboard`. |
| Placement | [rules](../../lua/lunette-plugins/rules/README.md), [placement](../../lua/lunette-plugins/placement/README.md), [adoption](../../lua/lunette-plugins/adoption/README.md), [arrangement persistence](../../lua/lunette-plugins/arrangement/README.md) | [default rules](../../lua/lunette-plugins/desktop/rules/README.md), [window adoption](../../lua/lunette-plugins/desktop/adoption/README.md) |
| Layout | [tags](../../lua/lunette-plugins/tags/README.md), [layouts](../../lua/lunette-plugins/layouts/README.md) | [workspaces](../../lua/lunette-plugins/desktop/workspaces/README.md), [arrangement](../../lua/lunette-plugins/desktop/arrange/README.md), [arc layout](../../lua/lunette-plugins/layout/arc/README.md) |
| Audio | [audio](../../lua/lunette-plugins/audio/README.md), [audio analysis](../../lua/lunette-plugins/audio-analysis/README.md) | [backdrop](../../lua/lunette-plugins/desktop/backdrop/README.md) |
| Errors | [errors](../../lua/lunette-plugins/errors/README.md) | [error display](../../lua/lunette-plugins/desktop/errors/README.md) |
| Rendering rates | [pacing](../../lua/lunette-plugins/pacing/README.md), [scale](../../lua/lunette-plugins/scale/README.md) | [window pacing](../../lua/lunette-plugins/desktop/pacing/README.md), [output scale](../../lua/lunette-plugins/desktop/scale/README.md) |

## Default configuration

The shipped desktop opens no applications. [Desktop configuration](../guide/desktop-configuration.md) covers settings and patches; [composition](../../lua/lunette-plugin/configuration-and-composition.md) specifies validation and startup.

The desktop protects the manager and its VR recovery controls from runtime removal. [Runtime manager](../guide/runtime-manager.md) describes these controls; [session management](../../lua/lunette-plugin/configuration-and-composition.md#start-and-manage-a-session) specifies protection and recovery. Direct raw-runtime mutation bypasses that protection.

## Service connections and outages

Optional children isolate dependencies: losing a service removes the feature that needs it, rather than the whole desktop component.

```text
audio -> audio-analysis -> backdrop response
  |                         (optional child)
  +-> independent audio consumers

frame + panels -> desktop/render -> panel drawing
                         |
                         +-> panels + surfaces -> picking child
frame + laser + surfaces -> desktop/pointing
```

An audio outage leaves the backdrop visible. A surfaces outage leaves panels drawing but stops picking. Keyboard-display loss removes the Keyboard action without removing Reload. A menu outage removes workspace actions without changing workspace visibility. Each plugin README describes its optional features.

## Placement

Rules, persistence, adoption, and arrangement can be replaced independently:

```text
configured rules ----+
saved arrangement ---+-> rules -> placement <- adoption <- desktop/adoption
native lunette.pose -+                ^
                               panels + tags

interaction -> drops -> pose memory / persistence / arrangement
layouts + tags + placement + panels -> desktop/arrange
```

Rule sources apply in ascending [precedence](../../lua/lunette-contracts/vocabulary.luau), with configured rules below saved arrangements and saved arrangements below `lunette.pose`. An inserted source belongs before `desktop/adoption`, so it registers before the first window resolves.

Pose memory belongs to the adoption consumer: it writes dropped poses and registers the source that reads them together. Splitting those halves across a consumer and a replaceable provider would lose hand-placed poses when the provider changes. Persistence owns disk storage; arrangement owns layout application.

## Other shared boundaries

Small VR controls use the UI service; larger interfaces remain Wayland clients. The menu broker and its renderer are replaceable independently. [Service contracts](../../lua/lunette-contracts/README.md) specify these shared boundaries.

## Pacing and scale

Providers select rates and scales; desktop consumers measure the scene and apply them. Changing selection policy does not require replacing scene observation. The consumers restore their changes on unload. [Rendering](rendering.md#frame-pacing-and-scene-skipping) and [outputs](compositor.md#outputs) specify native mechanisms.

## Decisions

Separate consumers preserve independent outages and allow replacement without copying unrelated policy. A fixed sequence in a configuration file would prevent reuse of the desktop. Stable entry ids make settings, patches, errors, and runtime inspection refer to the same plugin; short setting aliases made provider and consumer targets ambiguous.

Contract modules remain separate from implementations, so consumers can use replacement providers. The desktop root only composes plugins. [Repository conventions](../../CONTRIBUTING.md#lua-conventions) specify module ownership; [configuration decisions](../../lua/lunette-plugin/configuration-and-composition.md#decisions) specify typing and merging.

## Deliberately left open

The checker validates service shapes, not which provider a graph resolves. Whether static checking should validate graph wiring remains open.
