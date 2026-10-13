# Titlebar behavior

`desktop/decorations` creates one shared UI titlebar for each live native panel without its own panel chrome. It updates titlebar options in the `scene` phase and draws titlebars in that phase. A hidden panel's titlebar is not visible. A removed panel's titlebar is destroyed when the panel removal is announced, so the surface is not offered after its panel.

The optional `style` setting overrides the shared UI titlebar style. The schema is in [`config.luau`](../config.luau). Joined geometry and attachment lifetime are specified by [Joined frame attachments](../../../../../docs/dev/lua-api.md#joined-frame-attachments) and [Joined flat frames](../../../../../docs/dev/rendering.md#joined-flat-frames).

## Window actions and movement

A window titlebar displays the panel title, or the source window title when the panel has no title. Its close action requests that the application close. The panel remains until the client unmaps the window. A refused close request is raised from the action and reported at its callback boundary.

A grip on the panel or titlebar, or trigger on the titlebar background, moves the panel. The interaction provider emits a drop when the grab ends. The titlebar identifies the moved panel in that drop so placement consumers can record its pose. [Panel movement](../../../../../docs/guide/desktop-configuration.md#panel-movement) describes the controller workflow; [Drag and drop](../../../../../docs/dev/input.md#drag-and-drop) specifies native drag behavior.

## Monitor actions

A monitor titlebar provides Restart mirror and a close action. Restart dismisses the current capture and requests a new mirror. Close dismisses the capture and removes the mirror panel; it does not unplug the host monitor.

For monitors without direct capture, the titlebar also provides monitor selection through the host portal. A pending request disables the action and displays `Waiting for permission`. A failed request displays a retry action and the failure message. The consumer does not retry automatically. Cancelling the portal dialog keeps existing mirrors. Stopping screen sharing from the host desktop stops portal mirrors, but leaves their panels in place without frames; the portal is not asked again until monitor selection is requested. These capture workflows remain in [Monitors and titlebars](../../../../../docs/guide/desktop-configuration.md#monitors-and-titlebars).

## Deliberately left open

The consumer gives a titlebar to every native window, including a window whose `serverSideDecorations` is false because the client draws its own titlebar. Such a window shows two titlebars. The shared titlebar carries the grab and close controls, while the client's titlebar receives pointer input only and cannot move the panel in space. Hiding the shared titlebar for those windows needs another VR handle for moving and closing them, such as grip on the panel alone or a slimmer bar. The choice remains open until it can be tried on hardware.
