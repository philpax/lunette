# Service contracts

Plugin authors import `@lunette-contracts/<name>` to depend on a service rather than its provider. The [Luau declarations](.) own versions and data shapes. Replacement providers preserve the behavioral guarantees in [input](docs/input.md), [panels and UI](panels-and-ui.md), and [policy services](policy-services.md).

Registrations and notifications end with their owner or explicit disposal. Providers reject fields not named by the contract, protect callbacks made for other plugins, and report failures without stopping other callbacks. Inspection returns metadata without invoking callbacks or granting authority. [Ownership and lifecycle](../lunette-plugin/ownership.md) defines frozen service views, revocation, and caller-owned acquisition; the [native runtime](../../docs/dev/architecture.md#plugin-runtime) owns matching and cleanup.
