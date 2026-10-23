# Writing plugins

Plugins declare the services they require or provide and acquire resources during activation. The runtime starts consumers while their providers are available and ends their resources on unload. The [facade](../../lua/lunette-plugin/README.md) defines this lifecycle; [service contracts](../../lua/lunette-contracts/README.md) define behavior shared by replacement providers.

## Module responsibilities and imports

The native `@lunette` API supplies mechanisms. The plugin facade owns activation and effects, contracts define shared service behavior, and plugins implement policy. The desktop root composes plugins. A consumer imports a contract and obtains its service through `context:require`, rather than importing the provider's implementation.

Shipped plugins live under [responsibility categories](../../lua/lunette-plugins/README.md), including providers and desktop consumers. Module paths do not determine capability names or composition entry ids: `@lunette-plugins/input/keyboard-display` has the entry id `desktop/keyboard`. Each leaf has an independent entry. Categories have no activation module.

The standard library is read-only, and its global names, such as `math`, `type`, and `pairs`, cannot be reassigned. A plugin that needs different behavior provides it through a service or its own module rather than patching a library.

Supported author imports are a plugin's entry, its declared config module, its deliberate extensions, and exact public libraries. A neighbouring source file is not implicitly public. Private sources linked as implementation references do not become supported imports. The plugin guides define this boundary, and the [production dependency check](../../crates/lunette/tests/plugin_dependencies.rs) guards resolved source imports.

## Start a configuration

Start with the [copy/check workflow](../users/desktop-configuration.md#copy-and-check-a-configuration). Local plugin modules live beside `main.luau`; relative requires resolve from the requiring file in both a session and `lunette check`. The examples below are checked repository sources, not fragments to complete.

## Define a consumer

[`examples/first-plugin/hello.luau`](../../examples/first-plugin/hello.luau) is a complete consumer that draws through the frame service. It imports a neutral contract, declares its capability in `requires`, reads the service through `context:require`, and registers a draw handler with the context as owner.

[`examples/first-plugin/main.luau`](../../examples/first-plugin/main.luau) inserts its `definition` into the desktop by a stable entry id. Copy the example's adjacent modules into the configuration directory, then check and start it. No provider implementation import is needed.

## Declare a contract and provider

The [clock contract](../../examples/first-plugin/clock.luau) and [clock provider](../../examples/first-plugin/clock-provider.luau) show a typed capability and the service returned by a provider's `build`. Providers and consumers must agree on the capability's name and positive version. Supply the service type when declaring the capability; runtime matching does not check service fields.

Only one active plugin provides a capability. A service that needs several contributors uses owner-scoped registration, as the menu and layout brokers do.

## Configuration and effects

[`examples/first-plugin/uptime.luau`](../../examples/first-plugin/uptime.luau) derives optional `Config` and resolved `Settings` from one schema, consumes two services, and subscribes to a native event. [Configuration schemas](configuration-schema.md) covers merging and validation. Three-dimensional positions, directions, and offsets use native vectors.

Shared values use [neutral contract schemas](../../lua/lunette-contracts/schemas/README.md), without importing providers or acquiring resources.

Keep mutable state and acquisition inside `init` or `build`. Register subscriptions with `context:on`, and native resources with context effects or owner-scoped service methods. Module bodies must be safe to require again during source reload; the host has no teardown registry for resources acquired outside plugins. [Ownership and lifecycle](../../lua/lunette-plugin/ownership.md) states acquisition, partial-failure, and cleanup rules.

## Shared rendering and registration

Public [graphics libraries](../../lua/lunette-plugins/graphics/README.md) handle pass-state restoration, client pixels, and rounded drawing. Custom renderers still own their native resources and preserve the [rendering limits](native-api.md#windows-and-textures). Importing a drawing library does not start a provider.

Providers with several contributors can use the [registration libraries](../../lua/lunette-plugins/registration/README.md) for owner-scoped listeners or named values. [Lifecycle cleanup](../../lua/lunette-plugins/lifecycle/cleanup.luau) runs every release step even when one raises. These libraries do not replace context-owned acquisition or the service's contract guarantees.

## Configure or replace an entry

Desktop settings configure built-in entries by id. Patches replace, disable, or insert definitions and may configure a replacement. A setting and a patch cannot target the same id. Use the [desktop example](../../examples/desktop/main.luau) for the complete composition and [composition rules](../../lua/lunette-plugin/configuration-and-composition.md) for factories and typed patches.

## Hooks

A hook receives its normal arguments followed by `base`. Calling `base` retains the default behavior; omitting it replaces that behavior. Hooks are synchronous. [`examples/keyboard/split.luau`](../../examples/keyboard/split.luau) adds feedback while preserving key handling. Each provider documents its hook constraints.

## Extend the keyboard

The [split keyboard](../../examples/keyboard/split.luau) changes layout through the existing provider. The public [hook types](../../lua/lunette-plugins/input/keyboard/hooks.luau) and [legend renderer](../../lua/lunette-plugins/input/keyboard/legend.luau) support custom key handling and drawing without access to private rendering code. The [tiny keyboard](../../examples/keyboard/tiny.luau) replaces the provider and implements the [keyboard contract](../../lua/lunette-contracts/keyboard.luau). Keyboards register resources on the requesting owner's lifetime and are offered and drawn by their consumer. See the [keyboard plugin](../../lua/lunette-plugins/input/keyboard/README.md).

## Restyle the interface

The [theme provider](../../lua/lunette-plugins/ui/theme/README.md) owns the session's one theme. Its settings and service choose the light or dark mode and the accent, and the accessibility settings apply high contrast and text scale. A plugin restyles the toolkit by overriding kinds and visuals, as [Extension](../development/ui/extension.md#visuals) describes. Surfaces drawn outside the toolkit, such as the virtual keyboard, the laser, the mouse cursor, and window outlines, read the [theme contract](../../lua/lunette-contracts/theme.luau) and follow its changes through `onChanged`.

## Add a layout

[`examples/layout`](../../examples/layout) registers a named layout and selects it through `desktop/arrange`. Layouts arrange caller-supplied panels without owning them. The [follow layout](../../examples/layout/follow.luau) shows repeated application. The public [arc geometry extension](../../lua/lunette-plugins/layout/arc/geometry.luau) computes angles and poses without registering a layout or acquiring panels.

## Change pointer behavior

[`examples/desktop/upright.luau`](../../examples/desktop/upright.luau) extends the interaction provider's movement constraint. A custom drive hook can use public [picking and scrolling arithmetic](../../lua/lunette-plugins/interaction/picking.luau) while preserving the service's input guarantees. See the [interaction](../../lua/lunette-plugins/interaction/pointers/README.md) and [laser](../../lua/lunette-plugins/input/laser/README.md) plugins for hooks and pointer configuration.

A replacement provider that carries surfaces must preserve [capture cancellation](../../lua/lunette-contracts/docs/input.md#surface-pointer-delivery) and [drop notifications](../../lua/lunette-contracts/docs/input.md#drops). The desktop uses drops to save placement.

## Add session controls

[`examples/desktop/hide-windows.luau`](../../examples/desktop/hide-windows.luau) adds a wrist-menu action. Actions keep workflows reachable in VR; key bindings are optional additions. [The UI guide](ui.md) and [`examples/ui`](../../examples/ui) show a menu-opened form with the shared keyboard.

## Other desktop extensions

- [Save and restore placement](../../examples/desktop/save-menu.luau) through the arrangement service.
- [Present errors](../../examples/desktop/notify-errors.luau) without replacing error capture.
- [Consume audio and analysis](../../examples/audio-backdrop) independently of the backdrop, with readers owned by the plugin context.

## Check a configuration

`lunette check DIR` checks types without running initializers. Managed startup validates every entry's settings before activating any plugin. Initializer failures remain activation errors, so a successful check still needs a session test of behavior and unload. The [native API guide](native-api.md) covers handle, texture, reload, and error-boundary hazards.
