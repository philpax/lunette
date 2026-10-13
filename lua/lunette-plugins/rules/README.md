# Window rules

The rules provider resolves window properties from ordered, owner-scoped sources. The desktop rule-list consumer is separate, so configurations can replace the list without replacing resolution.

| Provides | Consumer requires |
| --- | --- |
| `lunette/rules` | `lunette/rules` |

[Provider options](config.luau) · [Consumer options](../desktop/rules/config.luau) · [Contract](../../lunette-contracts/rules.luau) · [Resolution policy](docs/rule-resolution.md)
