# Recovery

Keeps the session operable in VR when the UI toolkit fails. The plugin requires the composition, the error stream, the frame service, and the surfaces service, and none of the toolkit's capabilities. It draws its own panel with LÖVR passes, so its text does not go through the toolkit, and it offers the panel for ray picking. Its controls are reachable by controller ray only, because it does not use the toolkit's focus traversal. The shipped desktop composes it as `diagnostics/recovery` and protects it.

The panel appears in front of the head when a toolkit capability has no active provider, or when the host reports errors on many consecutive frames. Recovery polls the composition's compact health observation rather than full runtime inspection. Active child providers count, and changes to entry order, enabled state, or configuration values restart the healthy interval. Host errors are recognised by the context prefix of the report, because error reports carry no owner. The panel lists the recent errors and offers these actions:

- Default appearance, which toggles the host's default appearance. It reaches the host through an optional child plugin, so it is disabled, with the reason shown, while the host is not running.
- Reload configuration, through `lunette.reload`.
- Restore the last known good configuration. The plugin marks the composition good through the composition service once the toolkit has stayed active and free of host errors for a configured time under an unchanged composition. Restoring disables, reconfigures, restores, and enables entries through the composition service until the composition matches the mark. Protected entries are left alone. The mark lives in memory for the session.
- Set saved settings aside. Every entry that runs with [saved settings](../../storage/README.md#saved-settings) returns to its configuration from `main.luau` until the next start. The saved settings stay, marked suspended, so the runtime manager's Saved tab can forget the one at fault.
- Restart into safe mode, through `lunette.restartIntoSafeMode`. The next boot runs the compiled-in safe mode instead of the configuration.

The panel sets a pick priority on its surface, so picking prefers it over nearer surfaces, including a broken host's. A pointer `drive` hook configured on the interaction provider receives every offered surface and can still choose another target; the recovery panel does not bypass such a hook.

[Options](config.luau) · [Composition contract](../../../lunette-contracts/composition.luau) · [Error stream](../error-stream/README.md) · [Runtime manager](../../../../docs/users/runtime-manager.md#recovery)
