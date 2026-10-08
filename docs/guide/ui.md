# UI panels

`@lunette-contracts/ui` declares `lunette/ui` at schema 1. The service creates owner-scoped flat VR panels with buttons, single-line text fields, choices, lists, and custom regions. `lua/lunette-contracts/ui.luau` is the source of truth for the public types. `@lunette-plugins/ui` implements the contract and requires focus and surfaces. Consumers import the contract rather than the provider's internal modules.

## A public-contract example

`examples/ui/main.luau` adds a movable form to the shipped desktop. The Open example form action in the wrist menu opens it. The form includes a button, a Name text field, a Mode choice, a scrollable destination list, a custom preview region, and Close. The Name field uses the existing shared keyboard. Grip moves the panel, and the thumbstick scrolls the destination list. The source imports only neutral service contracts and retains its resources inside the plugin activation.

The configuration inserts the form by entry id:

```luau
local desktop = require '@lunette-desktop'

desktop.run {
  patches = {
    { insert = { id = 'example/ui/form', definition = require './form' } },
  },
}
```

`examples/ui/form.luau` creates the panel with its context as the owner. The provider offers the panel as a surface, but the consumer supplies the frame drawing order. The text-field fragment keeps the value in activation-local state:

```luau
panel:textField(context, {
  id = 'name',
  label = 'Name',
  bounds = { x = 24, y = 96, width = 552, height = 48 },
  value = text,
  onChange = function(value: string)
    text = value
  end,
})
```

The same source registers an owner-scoped menu action and frame callback. Each checks the current activation and panel before using it. Close hides the panel; the UI provider cancels captures and blurs field focus. Owner disposal removes the panel, controls, menu action, and frame callback. The custom preview delegates base drawing, then measures and draws its text within `visual.clip` using the public default font.

The strict checker checks this configuration. `lua/lunette-desktop/tests/example_ui.luau` runs its form workflow, movement, close, removal, and application hand-off with the built-in and independent substitute UI providers. `tests/vr-migration.luau` beside it combines the form with manager Search, provider outages, and production source reloads. These logic-headless tests do not establish GPU or headset presentation. The [runtime manager](runtime-manager.md) uses the same UI service and shared keyboard.

## Geometry and input

`width` and `height` are world-space metres. `logicalWidth` and `logicalHeight` define the panel's logical coordinate space. Logical coordinates start at the top-left corner, with x increasing rightward and y increasing downward. Bounds use half-open intervals: the left and top edges are inside, and the right and bottom edges are outside. Bounds and dimensions must be finite. Panel dimensions must be positive. Control widths and heights may be zero; zero-area controls do not receive input.

The same declared bounds determine pointer input, drawing, and `panel:describe()`. Controls and item bounds are clipped to the panel. A higher `z` wins overlapping input; later registration wins a tie. A custom region declares item bounds and optional routes explicitly. Drawing a larger shape does not enlarge a control's input bounds.

Each pointer button captures its original control until release or cancellation. Leaving a control does not transfer a held gesture to another control. Hiding a panel, disabling or destroying a control, changing a panel's size, or replacing control bounds or items cancels the affected gesture without activating it. `Panel:setPose` preserves captures during rigid motion and updates projected coordinates. Beginning a grip-driven grab cancels pointer gestures before motion. An exclusive control excludes another pointer while captured. Hover does not change keyboard focus. Text fields use local focus targets, and a region requests keyboard routing explicitly through its receiver and `wantsKeyboard` options.

## Shared titlebars

A panel opts into the shared titlebar with `titlebar = { title = 'Plugins', onClose = close }` in its creation options. `Panel:setTitlebar(options)` adds or updates it, and `Panel:setTitlebar(nil)` removes it. The callback owns close policy; the titlebar does not hide or destroy its target automatically. The shared X button calls `onClose` when present.

`actions` supplies extra titlebar buttons with stable `id`, `label`, and `run` fields, plus optional `enabled` and `width` values. Width is a multiple of the bar height, bounded by a share of the available panel width. `closeId` overrides the X button's id. `draggable = false` disables titlebar grabbing for tracked panels such as the wrist menu.

The bar sits above the panel body and follows its current pose, size, and visibility without changing the body's logical dimensions. The built-in provider's `titlebarStyle` supplies one shared style. A titlebar's optional `style` overrides individual fields over that provider style, and colour values replace complete lists. Native decorations, the manager, the keyboard display, and the expanded wrist menu use the same implementation. The compact wrist button and unheaded notices remain undecorated. The background supports trigger dragging, and grip remains available on movable panels. Hidden or destroyed targets cancel held titlebar controls.

Other owning surfaces attach the same implementation through `Service:newTitlebar(owner, name, target, options, visible?)`. The target supplies current pose, width, height, liveness, and movement. An optional visibility callback excludes a hidden target. The returned handle supplies `update`, `sync`, `draw`, and `destroy`; the consumer draws it in its own frame phase. Opted-in UI panels synchronize and draw their bars automatically. Titlebar action controls are described on a separate UI panel named `<panel name>/titlebar`.

## Text fields

Text fields accept valid single-line Unicode UTF-8. Control characters and line separators are rejected. `setSelection(caret, anchor?)` uses one-based UTF-8 byte offsets at extended grapheme boundaries. Omitting the anchor collapses the selection. The empty string has boundary `{ 1 }`, and every non-empty boundary list includes the terminal offset `#value + 1`. A selected range excludes its terminal boundary. Movement, deletion, selection, truncation, and insertion preserve whole grapheme clusters, including combining marks and emoji sequences.

`lunette.textBoundaries(text)` supplies these boundaries through the native Unicode segmentation implementation. It returns a fresh array and rejects invalid UTF-8. It does not provide shaping, bidirectional layout, or an IME or preedit protocol. The default renderer measures and draws with the same LÖVR font. It shows clipping or overflow explicitly rather than silently displaying a partial grapheme.

`onChange`, `onSubmit`, and `onCancel` receive the current string. Escape blurs before `onCancel` runs. Widget callback failures produce one owner-labelled report without undoing a committed draft or blur; the valid key or text operation remains consumed. Raw region receiver failures produce a failed focus-source result and never reach an application. `validate` returns an error string or nil. `setError` can present an external validation error. Focus sources deliver physical committed text and virtual key activations through the focus contract; the UI service does not bypass that routing with direct native sink delivery.

## Shared keyboard display and menu actions

A text field requests the shared desktop keyboard through its local focus target. It does not require `lunette/keyboard-display` directly. In a composition containing `desktop/keyboard`, focusing the field shows the single reused board. Switching fields keeps its pose. Hiding the board ends the matching field focus and preserves its draft; a fresh field click resumes editing. A manually shown board remains visible after editing ends. The display service's `show`, `hide`, `toggle`, `isVisible`, and owner-scoped `onChanged` operations are defined by `@lunette-contracts/keyboard-display`.

`@lunette-contracts/menu` defines the owner-scoped action broker. An action registration supplies a stable id, a label, a callback, and optional group, order, enabled, and selected values. Registration returns an effect, and owner unload removes the action. State updates use the original owner and effect. Action descriptors are immutable and contain no callbacks. A rendering consumer passes the descriptor's registration token to `invoke` so a retained row cannot invoke a replacement with the same id. The built-in broker does not render a wrist menu. The shipped `desktop/menu` consumer renders broker actions through the UI service, and `desktop/actions` registers reload and shared-keyboard actions. [Menu actions](../dev/lua-api.md#menu-actions) defines validation, ordering, and invocation results.

## Themes and drawing hooks

The built-in provider accepts `theme` overrides and a `draw` hook. Panels and controls accept narrower overrides of the same types. Resolution applies provider, panel, and control overrides in that order. A colour list replaces the complete colour value. `setTheme(nil)` removes an object's override and restores its inherited theme.

A draw hook receives `(pass, visual, base)`. The visual is an immutable snapshot with logical bounds, clipping bounds, the resolved theme, interaction state, and widget data. The provider hook wraps the default renderer, the panel hook wraps the provider renderer, and the control hook wraps the panel renderer. Calling `base(pass, visual)` preserves the wrapped renderer; omitting it replaces the drawing. A hook can change appearance, but cannot alter declared bounds or clipping bounds passed to `base`.

Hooks draw in logical panel coordinates beneath the panel-to-world transform. They start with the default shader and font, no material, no culling, and depth testing and depth writing disabled. Built-in widgets use the same state so internal painting does not depend on scene depth. Custom geometry must stay within `visual.clip`. The renderer restores the pass state and transform around each invocation, including when a hook raises. A hook must balance its own stack pushes, must not pop a stack entry it does not own, and must not retain the pass for later use. Arbitrary pass misuse is outside the restoration guarantee. Errors continue to the surrounding frame error boundary.

## Ownership and replacement

Panel names are unique within one provider activation. Control ids are unique across all live panels for the actual owner passed to the control's creation method. Different owners can reuse an id within the same panel; one owner cannot reuse it in another live panel until the earlier control ends. Panel ownership does not replace the control's creation owner. The owner must be live and bound to the provider. Owner unload, provider replacement, and source reload invalidate handles and release their surface offers, captures, and control-held focus resources. A callback retained from an ended activation must not affect a replacement panel.

The UI provider registers the underlying focus target under its own context. The control's owner-held inverse releases that target, so its lifetime follows the control. Cleanup attempts the remaining releases and rethrows failures rather than swallowing them. A failure raised during control-owner cleanup remains visible at that owner's inverse boundary; direct destruction raises it to the caller. Receiver errors are annotated with the control owner's label and rethrown to the focus delivery boundary. This does not change the underlying focus target's registration owner to the control owner.

`panel:describe()` returns a detached read-only snapshot. `description.generation` is a frozen `ui.Generation` token shared by panels from one provider activation. A replacement activation creates a different token, even when it reuses the same panel names and control ids. Each control handle and control description carries a read-only `owner` field containing a frozen `ui.OwnerIdentity` token. That token is stable for one owner activation within the UI provider and changes after an owner or provider replacement. It exposes no context, methods, or scripting authority.

The generation token, owner token, and control id together disambiguate a live control. An id alone is insufficient because different owners can reuse it in the same panel. Tokens are compared by reference identity; their `kind` fields are discriminators, not activation identifiers. `description.revision` tracks changes within the panel's activation. Consumers discard cached handles and descriptions when the relevant token changes and check a handle's `dead` field before use.

## Known gaps

The copied-install checker and module-load regressions cover both feature sets through the custom test runner and installed manifest roots. They do not exercise LÖVR's production virtual-filesystem mounting or an installed session boot. GPU-backed drawing and in-headset workflows remain separate acceptance gates.

The UI service is a bounded toolkit for local VR controls. The wrist menu and runtime manager consume it, and their focused fields reuse the shared desktop keyboard. The checked `examples/ui` configuration and its real-runtime scenarios cover the public form workflow with built-in and independent substitute providers. Full text shaping, bidirectional editing, IME composition, general layout containers, and a complete desktop widget framework are outside the current contract. The built-in renderer caches 32 recent text layouts and 32 label truncation results per font without retaining the font. Unchanged cached results avoid repeated substring measurement, but cold misses and cache churn still perform exhaustive searches with worst-case quadratic measured-text work. Long changing drafts have no verified frame-time bound. GPU-backed drawing and in-headset acceptance remain unverified by the type-check fixtures.
