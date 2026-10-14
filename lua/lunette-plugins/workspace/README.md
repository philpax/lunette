# Workspace

Workspace separates shared panel groups from workspace visibility policy.

## Plugin leaves

- [Tags](tags/README.md) stores named panel groups without defining their effect on visibility.
- [Controller](controller/README.md) selects a configured workspace and hides panels assigned elsewhere. It preserves hiding owned by other plugins.

The [tags contract](../../lunette-contracts/tags.luau) and [policy guarantees](../../lunette-contracts/policy-services.md) define memberships. The controller uses the [panels](../../lunette-contracts/panels.luau), [placement](../../lunette-contracts/placement.luau), and [menu](../../lunette-contracts/menu.luau) contracts. [Workspace workflows](../../../docs/users/desktop-configuration.md#windows-monitors-and-workspaces) define session controls and follow behavior.

[Shipped plugins and public imports](../README.md)
