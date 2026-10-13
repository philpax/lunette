# Native panel titlebars

Adds a shared titlebar to native window and monitor panels. Configure the optional [`style`](config.luau) override to change its appearance.

| Requires |
| --- |
| `lunette/frame`, `lunette/panels`, and `lunette/ui` |

Window close requests the application's close; the panel remains until the client unmaps it. Monitor controls restart or remove a mirror without unplugging the host monitor. A portal monitor offers Select monitors again once its previous selection is no longer ready. [Host capture](../../../../docs/dev/host-desktop.md#identity-and-lifecycle) specifies permissions and revocation; [Monitors and titlebars](../../../../docs/guide/desktop-configuration.md#windows-monitors-and-workspaces) describes the workflow.

## Client titlebars

A client-drawn titlebar can coexist with this titlebar. The shared titlebar carries the VR grab and close controls; the client's titlebar cannot move the panel in space. Hiding the shared titlebar would require another VR control for moving and closing the panel. The choice remains open pending headset acceptance. See [Native headset tests](../../../../docs/dev/build-and-development.md#native-headset-tests).
