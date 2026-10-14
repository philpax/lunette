# Workspace

Workspace separates shared panel groups from visibility policy. [Tags](tags/README.md) stores named groups without defining visibility. [Controller](controller/README.md) selects a configured workspace and hides panels assigned elsewhere, preserving hiding owned by other plugins.

The [tags contract](../../lunette-contracts/tags.luau) and [policy guarantees](../../lunette-contracts/policy-services.md) define memberships. The controller uses [panels](../../lunette-contracts/panels.luau), [placement](../../lunette-contracts/placement.luau), and [menu](../../lunette-contracts/menu.luau). [Workspace workflows](../../../docs/users/desktop-configuration.md#windows-monitors-and-workspaces) define controls and follow behavior. [Shipped plugins](../README.md) defines public imports.
