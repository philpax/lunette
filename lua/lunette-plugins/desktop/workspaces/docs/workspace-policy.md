# Workspace policy

`desktop/workspaces` holds one tag for each configured workspace and selects one tag at a time. A panel in an unselected workspace is hidden through an owner-held visibility override. The consumer withdraws that override when the panel should be visible; it does not override visibility to show. A panel hidden by another plugin therefore stays hidden.

The tag contract owns membership and selection. [`config.luau`](../config.luau) owns workspace name validation and the `follow` default. Shared placement composition is specified in [Placement](../../../../../docs/dev/standard-plugins.md#placement).

## Selection and actions

The first configured workspace is selected unless an existing configured tag is already selected. Switching sets the selected override on the chosen workspace and clears the selection on the others. A selection change refreshes panel visibility. The menu-actions child registers one `desktop/workspace/<name>` action per workspace only when more than one workspace exists. It is a child so a menu outage does not change workspace selection or follow behavior.

## Placement

A placed window that belongs to no configured workspace joins the shown workspace. The consumer applies this rule regardless of the adoption entry's `tags` setting. Adoption therefore does not need a workspace tag.

When `follow` is true, a newly placed window whose configured-workspace tags are all unselected is removed from those workspace tags and added to the selected workspace. A window already in a selected workspace stays there. With `follow` false, a placed window that already belongs to an unselected workspace remains there. Panels placed before the consumer activates, such as during an outage, join the selected workspace only when they belong to no workspace; the consumer does not follow them from another workspace during that initial scan.

The consumer does not change tags outside its configured workspace list. It holds each configured tag while active. On unload, its visibility overrides and child menu actions end with their owners.

## Decisions

The shipped configuration uses one `main` workspace, so it adds no Workspaces menu group until a configuration names a second. Placed windows in no workspace join the shown workspace, so the relationship holds for every workspace list. Pointing adoption at the first workspace during composition was rejected because only the setting would do so; an equivalent patch or a runtime Configure edit would leave new windows outside every workspace.

Workspace actions are a child so a menu outage does not reveal hidden windows. Workspace chords are not shipped because session controls must be reachable through VR input. The default-composition decision remains in [Standard plugins](../../../../../docs/dev/standard-plugins.md#placement).

## Known gaps

Tags outside the configured list are not shown or hidden by this consumer. The guide documents the configuration workflow in [Workspaces](../../../../../docs/guide/desktop-configuration.md#workspaces).
