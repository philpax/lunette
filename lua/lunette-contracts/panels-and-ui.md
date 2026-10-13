# Panels and UI

## Panels

Consumers follow panel lifetimes through `onAdded` and `onRemoved`, not provider-private registries. The provider releases a panel before its owner's effect is disposed, so removal listeners still have authority. A panel removed during owner unload is not announced from that owner's inverse.

If only one dimension is supplied, the other follows the source aspect ratio and changes with source size; supplying both fixes the rectangle. Monitor aspect uses oriented logical size. A hidden panel is not drawn or picked and releases its layer immediately, but remains in `all` and `forSource`. Closing a window requests client closure without removing the panel. Closing a monitor dismisses its capture and removes the panel.

Scene content is clipped to rounded corners for drawing and picking; granted layers remain rectangular. A positive curve uses the same vertical arc for picking, scene drawing, and a granted layer, with radius `1 / curve` and width measured along the arc. [Rounded geometry](../lunette-plugins/theme/docs/rounded-geometry.md) specifies the built-in perimeter construction.

## Joined frames

The optional `attachFrame(owner, style)` relationship in [vocabulary](vocabulary.luau) attaches resolved header style. Creation and update validate and freeze the whole style before changing state. Only one live attachment may target a surface. Disposal is idempotent; updating a disposed attachment or dead target raises. Ineligible targets leave attachments dormant: panels join while live, visible, flat, and drawn in the scene; UI panels join while live and visible. The target draws an outline around body and header even when panel chrome is disabled. A titlebar releases its attachment when hidden, destroyed, or unloaded. Retained titlebars synchronize in the scene phase after source and decoration updates but before picking. [Panel rendering](../lunette-plugins/panels/docs/rendering.md#joined-flat-frames) specifies the built-in joined geometry.

## Keyboards

A keyboard is a surface that its owner places, offers, and draws. The service does not draw keyboards globally. Presses arrive through the offered surface; focus, pointer capture, and text batches belong to [Input](docs/input.md).

Visibility notifications follow actual state changes. Theme changes take effect before the keyboard's next input or draw. Legends do not write depth, and key hooks and full draws restore pass state and transforms even when a hook raises.

## UI geometry

UI panels use one geometry for input, drawing, and inspection: logical coordinates start at the top left and increase downward; control bounds are half-open and clipped to the panel. Higher `z` wins overlap, then later registration. A control belongs to its panel's owner unless creation names another owner. An owner and control id identify a live control, and ids are unique per creation owner across that provider's panels. The frozen `OwnerIdentity` identifies the creation-owner activation. Inspection reports live panel geometry, clipped control bounds, and item geometry without granting authority.

Control capture follows [Input](docs/input.md). A held control refuses a second pointer. Release activates only the pressed control and only inside it; cancellation does not activate it. Hiding, disabling, destroying, resizing, or replacing bounds or items cancels affected captures; changing panel pose does not. Hover does not take keyboard focus.

Text fields accept valid single-line UTF-8 and edit at grapheme boundaries using `lunette.textBoundaries`. Setting a value does not call the change callback.

Theme overrides resolve from global theme to provider, panel, and control. A draw hook wraps the default renderer without changing hit bounds. Hooks restore pass state and transforms even on error. Draw errors propagate to the frame boundary; widget callback errors are reported with the control owner. Depth offsets and text orientation are rendering choices in the [UI rendering notes](../lunette-plugins/ui/docs/rendering.md). Panels and controls end with their creation owners, the provider, and source reload. A control's focus target is registered under the UI provider and held by the control; focus protocol belongs to [Input](docs/input.md).

## Themes

The current theme is an immutable snapshot whose revision advances only when the effective theme changes. The most recent live selection wins as a whole theme; updating it keeps its rank, and disposing it reveals the previous selection or base. Invalid overrides raise without changing state.

Change notifications run after a change, not upon subscription. State commits before delivery. A selection made during delivery schedules another round rather than recursing; revisions may coalesce, so consumers refresh from the current snapshot. The catalog registers validated, detached, complete themes and does not select them.

Appearance resolves from base theme through global theme, provider configuration, and object options. Omitted fields inherit; zero remains explicit. Consumers prepare measurements before publishing and retain the old appearance if preparation fails. Palette-only changes preserve pointer captures; font or geometry changes cancel affected captures after the new appearance is installed.

## Decisions

A general frame container was rejected because unrelated surfaces do not need layer or curve state. Theme fields are arbitrated as a whole rather than mixed field by field; the catalog remains separate from the replaceable selector so removing the selector leaves the base service available.

UI owner identities use activation tokens rather than counters, which could repeat after provider replacement. Control ids are owner-scoped because owners can contribute across panels and panels can have several owners. The keyboard contract has no programmatic key or text methods because consumers press through its surface and send text through focus.

## Known gaps

The UI toolkit has no text shaping, bidirectional editing, or IME composition. A draw hook cannot make arbitrary pass misuse safe.
