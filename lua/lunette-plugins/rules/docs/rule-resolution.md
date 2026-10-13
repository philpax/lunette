# Rule resolution

Rule sources resolve by ascending precedence, then registration order. Rules within a source apply in list order, with later values replacing earlier values. Function-valued named properties run after the sources merge. Resolution walks a snapshot, so registration changes do not alter an active resolution.

A rule may omit its match to apply to every window. Match fields accept typed literals or predicates; malformed tables and unknown match fields are rejected. Named placement properties can be computed from the window. Other string property names pass through for consumers that define their own data. Match fields and properties must be plain tables, and tags must be a list of strings.

The desktop rule-list consumer registers its configured rules through the provider. Its schema owns the rule list; the provider schema owns source precedence. Placement stays a separate service so rules do not depend on panels or tags.

[Rules contract](../../../lunette-contracts/rules.luau) · [Shared precedence and placement guarantees](../../../../lua/lunette-contracts/policy-services.md#rules-and-placement)
