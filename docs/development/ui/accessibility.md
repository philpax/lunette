# Accessibility

Accessibility combines session settings, node semantics, and complete VR workflows. Tokens and standard interaction response help kinds follow shared settings, but they do not prove that a consumer exposes every action without a physical keyboard or mouse.

## Settings

The [accessibility contract](../../../lua/lunette-contracts/accessibility.luau) and [provider schema](../../../lua/lunette-plugins/ui/accessibility/config.luau) own the supported settings. The provider publishes an observable store and persists changes through the plugin's saved settings. It does not own a separate versioned settings file.

The host applies text scale, high contrast, reduced motion, and haptics. Text scale reaches layout through typography, and reduced motion snaps the host's channels. A setting's presence does not imply every proposed body-profile placement, handedness-aware overlay, one-hand presentation switch, timing multiplier, sound, or visual-alternative consumer is implemented.

Default appearance retains accessibility settings. A theme override must not remove the recovery path to readable base appearance. Fixed-size panels need wrapping or scrolling when text scale changes rather than relying on their original dimensions.

## Roles and semantics

Kinds can declare a role and semantics. Node inspection reports role-bearing nodes with their accessible name, value, and state. The accessibility service relays explicit announcements from callers. It does not publish the proposed automatic event stream of every node appearance, value change, and focus move.

Assistive consumers can use inspection and public traversal. Those reads do not grant authority over other owners' panels or establish an unrestricted event-dispatch API. A custom canvas does not acquire separately focusable internal items without representing them as nodes or adding a public contract.

## One-handed use

A two-handed gesture is never the only acceptable path to a session action. Panel manipulation needs one-handed alternatives, and a zoomable canvas needs controls other than a two-hand gesture. A wrist menu must remain usable without requiring the same hand to touch its own wrist.

These are workflow requirements rather than claims that all proposed resize-frame, context-menu, and drag-and-drop alternatives exist. [#69](https://github.com/philpax/lunette/issues/69) tracks the input mechanisms and manipulation work. Focus traversal already provides a separate channel for controls that implement it, and consumers must verify their complete VR path.

## Colour and contrast

Body text needs a contrast ratio of at least 4.5 to 1 against its surface. Non-text boundaries and focus indicators need at least 3 to 1. These are design requirements, not a claim that a single theme test proves contrast over arbitrary translucent backgrounds and every interaction state.

Text surfaces need sufficient opacity because the underlying application or passthrough changes the background. State must not rely on colour alone. Disabled controls need a reason, and status colours need readable labels or another cue. The theme provides a high-contrast variant and contrast guards for supported colour choices.

Theme verification must use the actual pairs rendered by visuals. Token contrast alone does not establish the contrast of a custom volume, image, gradient, or user-chosen translucent surface.

## Target assistance

Ray filtering and trigger locking already reduce some selection errors. Bubble cursors, magnetic target selection, and missed-ray proximity queries need the deferred pick-hook contract in [#70](https://github.com/philpax/lunette/issues/70). They are not available host extension APIs.

Switch access can drive public traversal. A dwell or gaze workflow also needs a supported provider and complete cancellation and feedback rules rather than assuming a general interactor registry.

## Localisation

Native text supports shaping and fallback for display. Bidirectional editing and input-method composition remain unsupported. The host does not guarantee inherited right-to-left mirroring for every layout, slider, and traversal operation. [Layout and text](layout-and-text.md#open-questions) states the editing limitations.

Interface labels and titles use sentence case. Disabled reasons are full sentences that explain what makes the action available. Localization must preserve the complete VR workflow, including entry of the user's script, rather than relying on shaped display alone.
