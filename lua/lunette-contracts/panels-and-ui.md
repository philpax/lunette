# Panels and UI

Consumers and replacement providers preserve these resource, input, and appearance guarantees. The [contract declarations](.) own types; [input](docs/input.md) owns focus and capture routing.

## Panels

Follow `onAdded` and `onRemoved`, not private registries. Removal listeners run before owner authority ends; panels removed during unload are not announced from that owner's inverse. A hidden panel remains registered but is neither drawn nor picked and releases its layer. Window close requests client closure; monitor close dismisses capture and removes the panel.

One supplied dimension follows source aspect; supplying both fixes the rectangle. Drawing and picking share rounded and curved geometry, but granted layers stay rectangular at rounded corners. [Panels](../lunette-plugins/panels/README.md) describes the built-in renderer.

## Joined frames

The optional [frame attachment](vocabulary.luau) validates the whole style before changing state and allows one live attachment per target. Disposal is idempotent; updates after disposal or target death raise. Ineligible targets keep a dormant attachment: native panels join only when visible, flat, and scene-rendered; UI panels join while visible.

Targets draw the joined outline even without panel chrome. Hiding, destroying, or unloading a titlebar releases its attachment. Retained titlebars synchronize after source and decoration updates but before picking. See the [panel renderer](../lunette-plugins/panels/README.md).

## Keyboards

The caller places, offers, and draws its keyboard; the service does not draw globally or expose a second programmatic key-delivery path. Theme changes apply before the next input or draw, and visibility notifications follow actual changes. Drawing and hooks restore pass state even on error; legends do not write depth.

## UI geometry

Input, drawing, and inspection share top-left, y-down logical coordinates. Bounds are half-open and clipped to the panel. Higher `z` wins overlap, then later registration. Control ids are unique per creation owner across the provider's panels. Inspection identifies owner activations and reports geometry without granting panel authority.

A held control refuses other pointers. Release activates only the pressed control and only inside; cancellation never activates. Hiding, disabling, destroying, resizing, or changing bounds or items cancels capture; pose changes do not. Hover does not take focus. Text fields accept single-line UTF-8 and edit grapheme clusters; setting text does not invoke change callbacks.

Panels and controls end with their creation owners or provider. Widget errors report against the control owner; draw errors reach the frame boundary. Hooks restore pass state but cannot change hit bounds. The [UI provider](../lunette-plugins/ui/README.md) owns rendering choices. Arbitrary pass misuse, text shaping, bidirectional editing, and IME composition are unsupported.

## Themes

The current theme is immutable; revision advances only on effective change. The latest live whole-theme selection wins. Updating keeps its rank; disposal reveals the previous selection or base. Invalid overrides leave state unchanged. The catalog registers detached complete themes but does not select them.

Notifications follow committed changes, not subscription. Re-entrant selection schedules another round; revisions may coalesce, so consumers refresh the current snapshot. Appearance inherits through global theme, provider, and object overrides. Omission inherits, and zero is explicit. Failed measurement preparation retains old appearance; colors preserve capture, while font or geometry changes cancel it after installation. The catalog stays separate from selection so replacing the selector leaves the base theme available.
