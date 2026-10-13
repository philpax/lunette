# Theme selection

`desktop/theme` selects a named complete theme from `lunette/themes` and applies it through `lunette/theme`. The catalog selects nothing. The shared selection service defines how registrations compose and how consumers observe changes; see [Runtime themes](../../../../../docs/dev/lua-api.md#runtime-themes).

## Choice and fallback

The configured `preset` names the fallback catalog entry. The selector initially applies that entry with the configured sparse `overrides`. A theme menu action is registered for each catalog entry in catalog order, using the label `Theme: <label>` in the Appearance group. A choice updates the selector's one theme registration. The new choice therefore replaces the previous theme whole, after which the same sparse overrides apply to it.

The selector shows the user's choice while that name remains registered. If the choice is absent, it shows the configured preset when registered. If neither name is registered, it disposes its selection and the theme provider shows its square base theme. Disabling `desktop/theme` also ends the selector registration and returns the provider to its square base theme. The selector reports an unregistered wanted or configured name once, after the first `scene` update, so entries that register themes later in startup are not reported prematurely. Catalog changes synchronize menu actions and selection. If the missing theme registers later, it can become active.

Disabling the selected theme removes its catalog entry and falls back to the configured preset. Re-enabling the entry restores the user's choice unless the user chose another theme in between. Theme actions follow catalog order. If a live entry changes position, the selector replaces its action registration at the new position.

## Runtime lifetime

The selector is a factory. It retains the user's choice across activations of one runtime while the configured preset remains unchanged. A changed `preset` returns selection to that configured name. An edit to `overrides` alone keeps the session choice and reapplies the new overrides. Source reload starts a new runtime choice. The choice is not persisted.

The schema for `preset` and `overrides` is in [`config.luau`](../config.luau). Theme fields and validation are owned by [`lua/lunette-plugins/theme/descriptors.luau`](../../../theme/descriptors.luau). The configuration workflow and font option details remain in [Desktop configuration](../../../../../docs/guide/desktop-configuration.md#runtime-themes).

## Decisions

The selector updates one owner-scoped theme registration when the user chooses a theme, so the new theme replaces the previous selection as a whole. A catalog theme registration belongs to its owner and disappears with that owner. The selector follows catalog changes rather than retaining a detached theme value.

Missing-name reporting waits until the first frame update because later entries can register themes after the selector initializes. The selector logs each missing name once while it remains missing.

## Known gaps

A missing configured name produces no selector registration until it becomes available. The theme provider's square base theme remains effective when the selector has no registered choice.
