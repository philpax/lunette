# Service contracts

Import `@lunette-contracts/<name>` to depend on a service rather than a provider. The declarations own contract versions and shapes; the [plugin runtime specification](../../docs/dev/architecture.md#plugin-runtime) owns matching, publication, reservations, and cleanup.

Published services are frozen views. Assignment raises, and reads or calls through a saved view raise once its provider starts unloading. A method read while the provider is live remains callable; objects returned by it enforce their own liveness. Owner-scoped registrations and overrides end with their effect or registration, or when their owner unloads. Notifications end with their effect. Providers protect callbacks invoked for other plugins and report failures through `lunette.reportError` without stopping other callbacks. Calls reject fields the contract does not name. Broker inspection returns metadata without invoking plugin callbacks.

Declarations: [panels](panels.luau), [UI](ui.luau), [keyboard](keyboard.luau), [keyboard display](keyboard-display.luau), [theme service](theme.luau) and [theme catalog](themes.luau); [bindings](bindings.luau), [menu](menu.luau), [layouts](layouts.luau), [tags](tags.luau), [rules](rules.luau), [placement](placement.luau), [drops](drops.luau); [errors](errors.luau), [pacing](pacing.luau), [scale](scale.luau); shared [vocabulary](vocabulary.luau), [frame](frame.luau), and [surfaces](surfaces.luau).

[Panels and UI](panels-and-ui.md) covers panel lifetimes, joined frames, UI geometry, keyboards, and themes. [Policy services](policy-services.md) covers brokers, tags, rules, placement, errors, pacing, and scale. [Input](docs/input.md) owns frame dispatch, focus, pointer delivery, drops, and physical input batches.
