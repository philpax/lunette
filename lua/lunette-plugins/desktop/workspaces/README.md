# Workspaces

Shows one configured workspace at a time by hiding panels in other workspace tags. Configure [`names` and `follow`](config.luau). With `follow` enabled, a newly placed window assigned only to unselected workspaces moves to the selected workspace.

| Requires | Optional |
| --- | --- |
| `lunette/panels`, `lunette/placement`, and `lunette/tags` | `lunette/menu` and `lunette/tags` for workspace actions |

A placed window without a configured workspace tag joins the selected workspace, so it remains visible even when adoption assigns no tags. This makes the default workspace assignment independent of how adoption is configured.

The consumer only hides panels in unselected workspaces; withdrawing its visibility override does not reveal panels hidden by another plugin. Menu actions are optional so a menu outage does not change workspace visibility or selection. See [Workspaces](../../../../docs/guide/desktop-configuration.md#windows-monitors-and-workspaces).
