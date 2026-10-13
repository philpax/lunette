# Placement

The placement provider resolves window properties, creates panels, and holds their tag memberships. It can map resolved properties to panel options without coupling rule resolution to panels.

| Provides | Requires |
| --- | --- |
| `lunette/placement` | `lunette/panels`, `lunette/rules`, `lunette/tags` |

[Options](config.luau) · [Contract](../../lunette-contracts/placement.luau) · [Rules and placement guarantees](../../lunette-contracts/policy-services.md#rules-and-placement) · [Composition policy](docs/placement-policy.md)

The `panelOptions` callback extends or replaces the default property-to-panel mapping. Placement does not adopt windows; adoption is a separate provider and consumer.