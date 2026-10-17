# Service contracts

Plugin authors import `@lunette-contracts/<name>` to depend on a service rather than its provider. The [Luau declarations](.) own versions and data shapes. Replacement providers preserve the behavioral guarantees in [input](docs/input.md), [panels and UI](panels-and-ui.md), and [policy services](policy-services.md).

A contract module can also declare UI outlets, as [`plugin-manager.luau`](plugin-manager.luau) declares the plugin manager's settings outlet.

Shared vocabulary and [contract schemas](schemas/README.md) remain neutral. They define and validate values without importing a provider or starting a service. Editable plugin configuration stays with its owner; service contracts do not depend on settings projection or font-resource creation.

Registrations and notifications end with their owner or explicit disposal. Providers reject fields not named by the contract, protect callbacks made for other plugins, and report failures without stopping other callbacks. Inspection returns metadata without invoking callbacks or granting authority. [Ownership and lifecycle](../lunette-plugin/ownership.md) defines frozen service views, revocation, and caller-owned acquisition; the [native runtime](../../docs/development/architecture.md#plugin-runtime) owns matching and cleanup.
