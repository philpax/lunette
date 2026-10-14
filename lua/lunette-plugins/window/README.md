# Window

Window separates property resolution, rule sources, panel placement, and adoption. Replacing a rule list does not require replacing resolution, and placement does not adopt windows by itself.

## Plugin leaves

- [Rule resolver](rule-resolver/README.md) resolves properties from ordered sources.
- [Configured rules](configured-rules/README.md) registers the shipped rules or a replacement configured list.
- [Placement](placement/README.md) creates panels and tag memberships from resolved properties.
- [Adoption](adoption/README.md) connects eligible compositor windows to placement.
- [Adoption controller](adoption-controller/README.md) supplies default tags, filtering, and optional pose memory.

The [rules](../../lunette-contracts/rules.luau), [placement](../../lunette-contracts/placement.luau), and [adoption](../../lunette-contracts/adoption.luau) contracts define service access. The neutral [rules schema](../../lunette-contracts/schemas/rules.luau) owns shared value validation and field classification. [Policy guarantees](../../lunette-contracts/policy-services.md) and [placement precedence](../../../docs/development/standard-plugins.md#placement) define source ordering and initial adoption.

[Shipped plugins and public imports](../README.md)
