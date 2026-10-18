# Panels and UI

Consumers and replacement providers preserve these resource, input, and appearance guarantees. The [contract declarations](.) own types; [input](docs/input.md) owns focus and capture routing.

## Panels

Follow `onAdded` and `onRemoved`, not private registries. Removal listeners run before owner authority ends; panels removed during unload are not announced from that owner's inverse. A hidden panel remains registered but is neither drawn nor picked and releases its layer. Window close requests client closure; monitor close dismisses capture and removes the panel.

One supplied dimension follows source aspect; supplying both fixes the rectangle. Drawing and picking share rounded and curved geometry, but granted layers stay rectangular at rounded corners. [Panels](../lunette-plugins/panels/service/README.md) describes the built-in renderer.

## Joined frames

The optional [frame attachment](vocabulary.luau) validates the whole style before changing state and allows one live attachment per target. Disposal is idempotent; updates after disposal or target death raise. Ineligible targets keep a dormant attachment: native panels join only when visible, flat, and scene-rendered; UI panels join while visible.

Targets draw the joined outline even without panel chrome. Hiding, destroying, or unloading a titlebar releases its attachment. Retained titlebars synchronize after source and decoration updates but before picking. See the [panel renderer](../lunette-plugins/panels/service/README.md).

## Keyboards

The caller places, offers, and draws its keyboard; the service does not draw globally or expose a second programmatic key-delivery path. Theme changes apply before the next input or draw, and visibility notifications follow actual changes. Drawing and hooks restore pass state even on error; legends do not write depth.

## UI host

Panel coordinates are metres from the panel's top-left corner, with x right and y down; elevation is metres towards the viewer. Input, drawing, and inspection share these coordinates and the panel's curve. A node is hit only inside its bounds and inside every clipping ancestor. A raised node wins over a lower one, then the later sibling.

A press captures the pressed node for that pointer. Release activates only the captured node and only inside it, and cancellation never activates. Relayout keeps a capture, a pointer cancel from the interaction service cancels it, and removing the captured node ends it without an event. When a kind registration changes, a replacement at the same path with the same kind carries focus, common declared state fields, hover, and capture, so an active drag releases on the remade node. Hover does not take focus. Focusing a text field through pointing, traversal, or a focus request takes session focus and requests the shared keyboard. Text fields edit single-line UTF-8 at extended grapheme boundaries; Luau owns editing and caret mapping, and native segmentation supplies the boundaries. A value set through props does not call `onChange`.

Outlet contributions render once for each placement, with separate state, in the outlet's order or by contributor name, and the host rejects a contribution built against an incompatible version or a second declaration of a name and version with another schema. An attributed outlet frames and clips each contribution and names the contributing plugin. Panels, kinds, visuals, contributions, and nodes end with their creation owners or the host. Errors from kind handlers, visuals, and component callbacks are reported through the protected-call boundary and do not stop the frame. Node ids are stable key paths within a panel, and `inspect` and `inspectNodes` report geometry and semantics without granting authority over another owner's panels. The [UI host](../lunette-plugins/ui/host/README.md) records rendering limits. Bidirectional text and input-method composition are unsupported.

## Themes

The [theme provider](../lunette-plugins/ui/theme/README.md) owns the session's one theme, below the UI host. A resolved theme is immutable, and a change of mode, accent, or accessibility option resolves a new one, which `onChanged` listeners then receive. Consumers that draw outside the toolkit compare the theme they applied with the current one. Default appearance changes only the theme that toolkit panels draw with. Appearance inherits through the session theme, provider options, and object overrides. Omission inherits, and zero is explicit. A colour change preserves a keyboard capture, while a geometry change cancels it after installation.
