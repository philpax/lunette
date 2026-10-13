# Writing plugins

Plugins declare the services they require or provide and acquire resources during activation. The runtime starts consumers while their providers are available and ends their resources on unload. The [facade](../../lua/lunette-plugin/README.md) defines this lifecycle; [service contracts](../../lua/lunette-contracts/README.md) define behavior shared by replacement providers.

## Start a configuration

Start with the [copy/check workflow](../users/desktop-configuration.md#copy-and-check-a-configuration). Local plugin modules live beside `main.luau`; relative requires resolve from the requiring file in both a session and `lunette check`. The examples below are checked repository sources, not fragments to complete.

## Define a consumer

[`examples/first-plugin/hello.luau`](../../examples/first-plugin/hello.luau) is a complete consumer that draws through the frame service. It imports a neutral contract, declares its capability in `requires`, reads the service through `context:require`, and registers a draw handler with the context as owner.

[`examples/first-plugin/main.luau`](../../examples/first-plugin/main.luau) inserts its `definition` into the desktop by a stable entry id. Copy the example's adjacent modules into the configuration directory, then check and start it. No provider implementation import is needed.

## Declare a contract and provider

The [clock contract](../../examples/first-plugin/clock.luau) and [clock provider](../../examples/first-plugin/clock-provider.luau) show a typed capability and the service returned by a provider's `build`. Providers and consumers must agree on the capability's name and positive version. Supply the service type when declaring the capability; runtime matching does not check service fields.

Only one active plugin provides a capability. A service that needs several contributors uses owner-scoped registration, as the menu, theme catalog, and layout brokers do.

## Configuration and effects

[`examples/first-plugin/uptime.luau`](../../examples/first-plugin/uptime.luau) derives optional `Config` and resolved `Settings` from one schema, consumes two services, and subscribes to a native event. [Configuration schemas](configuration-schema.md) covers merging and validation. Three-dimensional positions, directions, and offsets use native vectors.

Keep mutable state and acquisition inside `init` or `build`. Register subscriptions with `context:on`, and native resources with context effects or owner-scoped service methods. Module bodies must be safe to require again during source reload; the host has no teardown registry for resources acquired outside plugins. [Ownership and lifecycle](../../lua/lunette-plugin/ownership.md) states acquisition, partial-failure, and cleanup rules.

## Configure or replace an entry

Desktop settings configure built-in entries by id. Patches replace, disable, or insert definitions and may configure a replacement. A setting and a patch cannot target the same id. Use the [desktop example](../../examples/desktop/main.luau) for the complete composition and [composition rules](../../lua/lunette-plugin/configuration-and-composition.md) for factories and typed patches.

## Hooks

A hook receives its normal arguments followed by `base`. Calling `base` retains the default behavior; omitting it replaces that behavior. Hooks are synchronous. [`examples/keyboard/split.luau`](../../examples/keyboard/split.luau) adds feedback while preserving key handling. Each provider documents its hook constraints.

## Extend the keyboard

The [split keyboard](../../examples/keyboard/split.luau) changes layout through the existing provider. The [tiny keyboard](../../examples/keyboard/tiny.luau) replaces it and implements the [keyboard contract](../../lua/lunette-contracts/keyboard.luau). Keyboards register resources on the requesting owner's lifetime and are offered and drawn by their consumer. See the [keyboard plugin](../../lua/lunette-plugins/keyboard/README.md).

## Add a theme

[`examples/theme`](../../examples/theme) registers a complete theme with the catalog and selects it in the desktop configuration. Registration ends with its owner. The [theme contract](../../lua/lunette-contracts/theme.luau) defines values; the [theme selector](../../lua/lunette-plugins/desktop/theme/README.md) describes runtime selection.

## Add a layout

[`examples/layout`](../../examples/layout) registers a named layout and selects it through `desktop/arrange`. Layouts arrange caller-supplied panels without owning them. The [follow layout](../../examples/layout/follow.luau) shows repeated application.

## Change pointer behavior

[`examples/desktop/upright.luau`](../../examples/desktop/upright.luau) extends the interaction provider's movement constraint. See the [interaction](../../lua/lunette-plugins/interaction/README.md) and [laser](../../lua/lunette-plugins/laser/README.md) plugins for hooks and pointer configuration.

A replacement provider that carries surfaces must preserve [capture cancellation](../../lua/lunette-contracts/docs/input.md#surface-pointer-delivery) and [drop notifications](../../lua/lunette-contracts/docs/input.md#drops). The desktop uses drops to save placement.

## Add session controls

[`examples/desktop/hide-windows.luau`](../../examples/desktop/hide-windows.luau) adds a wrist-menu action. Actions keep workflows reachable in VR; key bindings are optional additions. [The UI guide](ui.md) and [`examples/ui`](../../examples/ui) show a menu-opened form with the shared keyboard.

## Other desktop extensions

- [Save and restore placement](../../examples/desktop/save-menu.luau) through the arrangement service.
- [Present errors](../../examples/desktop/notify-errors.luau) without replacing error capture.
- [Consume audio and analysis](../../examples/audio-backdrop) independently of the backdrop, with readers owned by the plugin context.

## Check a configuration

`lunette check DIR` checks types without running initializers. Managed startup validates every entry's settings before activating any plugin. Initializer failures remain activation errors, so a successful check still needs a session test of behavior and unload. The [native API guide](native-api.md) covers handle, texture, reload, and error-boundary hazards.
