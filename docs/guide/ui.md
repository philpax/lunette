# UI panels

`@lunette-contracts/ui` declares `lunette/ui` at schema 3. Its service creates owner-scoped flat VR panels with buttons, single-line text fields, choices, lists, and custom regions. `lua/lunette-contracts/ui.luau` declares the public types. `@lunette-plugins/ui` implements the contract and requires the theme, focus, surfaces, and frame contracts. A consumer imports the contract, not the provider's modules, so another provider can replace the built-in one. The [UI provider README](../../lua/lunette-plugins/ui/README.md) records its configuration and dependencies.

## An example form

`examples/ui/main.luau` inserts a movable form into the shipped desktop, and the wrist menu's Open example form action shows it. The form has a button, a Name text field, a Mode choice, a scrollable list, a custom preview region, and Close. The Name field uses the shared desktop keyboard.

```luau
require('@lunette-desktop').run {
  patches = {
    { insert = { id = 'example/ui/form', definition = require './form' } },
  },
}
```

`examples/ui/form.luau` creates the panel with `widgets:newPanel(context, options)`, so the panel and its controls end with the plugin. A control belongs to the panel's owner unless its options name another `owner`. The provider offers the panel as a surface, and the consumer draws it from its own frame callback. A control keeps its value in the activation's own state:

```luau
panel:textField {
  id = 'name',
  label = 'Name',
  bounds = { x = 24, y = 96, width = 552, height = 48 },
  value = text,
  onChange = function(value: string)
    text = value
  end,
}
```

`lua/lunette-desktop/tests/example_ui.luau` runs the form with the built-in provider. The [runtime manager](runtime-manager.md) and the wrist menu use the same service.

## Geometry and input

A panel's `width` and `height` are in metres. `logicalWidth` and `logicalHeight` set its logical coordinate space, with the origin at the top-left corner, x increasing rightward, and y increasing downward. Control bounds are logical and half-open: the left and top edges are inside, and the right and bottom edges are outside. Panel dimensions are positive. A control with zero width or height receives no input.

Declared bounds define a control's input area and its entry in `ui:inspect()`. Drawing a larger shape does not enlarge it. Where a panel has rounded corners, controls and their input are clipped to a rectangular content area inside the rounded outline, which can leave less room near the corners. [UI rendering](../../lua/lunette-plugins/ui/docs/rendering.md) specifies the clip, depth, and titlebar geometry. A higher `z` wins overlapping input, and the later registration wins a tie. A custom region declares its items' bounds and optional routes.

Each pointer button captures the control it pressed until release or cancellation, and a held gesture never moves to another control. Hiding the panel, disabling or destroying the control, resizing the panel, or replacing the control's bounds or items cancels the gesture without activating it. `Panel:setPose` keeps captures. A grip grab cancels the pointer's gestures before the panel moves. A captured control ignores other pointers. Hover does not move keyboard focus. A region takes keyboard input through its `receiver` and `wantsKeyboard` options.

## Titlebars

`titlebar = { title = 'Plugins', onClose = close }` in a panel's options gives it the shared titlebar. `Panel:setTitlebar(options)` adds or changes it, and `Panel:setTitlebar(nil)` removes it. The titlebar's X calls `onClose`, which decides what closing means; the titlebar does not hide or destroy the panel itself. `actions` adds buttons, each with `id`, `label`, `run`, and optional `enabled` and `width`, measured in bar heights. `draggable = false` stops the titlebar from moving the panel, as on the wrist menu.

The bar sits above the panel and follows its pose, size, and visibility. Trigger on the bar outside its buttons moves the panel, and grip anywhere on a movable panel moves it. The provider's `titlebarStyle` option styles every bar, and a titlebar's `style` overrides individual fields.

`Service:newTitlebar(owner, { name, target, visible?, ...options })` attaches the same titlebar to another surface, such as a native window. `visible` is a predicate that hides the titlebar while it returns false. The returned handle has `update`, `sync`, `draw`, and `destroy`, and the consumer draws it. A flat target joins its body and titlebar into one outline when it implements `attachFrame`; [Joined frame attachments](../../lua/lunette-contracts/panels-and-ui.md#joined-frames) specifies the method.

## Text fields

A text field holds valid single-line UTF-8; control characters and line separators are rejected. `setValue` replaces the text and `value` returns it. Editing moves and deletes whole grapheme clusters, and a draw hook's `visual` carries the caret and anchor as one-based byte offsets. `lunette.textBoundaries(text)` returns those boundaries for a string. Text is not shaped, laid out bidirectionally, or composed through an input method.

`onChange`, `onSubmit`, and `onCancel` receive the current text; Escape blurs the field before `onCancel` runs. `setError` shows an error message, and Enter does not submit while one is shown. Editing the text clears it. An error raised by a callback is reported once with the owner's label and does not undo the edit. Keys and text reach a field through the focus contract, from a physical keyboard or the virtual one.

## Shared keyboard and menu actions

Focusing a text field shows the shared desktop keyboard when the composition includes `desktop/keyboard`. The field does not require `lunette/keyboard-display` itself. Hiding the keyboard ends the field's focus and keeps its text, and pointing at the field again resumes editing. A keyboard the user showed stays visible after editing ends. `@lunette-contracts/keyboard-display` defines `show`, `hide`, `toggle`, `isVisible`, `onChanged`, and `inspect`.

`@lunette-contracts/menu` defines the action broker. An action has an `id`, a `label`, a `run` callback, and optional `group`, `order`, `enabled`, and `selected` values. `register` returns a registration whose `update { enabled, selected }` changes it, and it ends with its owner or its `dispose`. `desktop/menu` draws the actions on the wrist and redraws them when `onChanged` reports a change. [Bindings, menu actions, and layouts](../../lua/lunette-contracts/policy-services.md#brokers) specifies the broker.

## Themes and drawing hooks

A panel's appearance resolves from the current theme, then the provider's `theme` option, the panel's `theme`, and the control's `theme`, each overriding the one before. A colour replaces the whole colour. An omitted field follows later theme changes, and an explicit zero is an override. `setTheme(nil)` removes an override. UI `panelRadius` and `controlRadius` are in logical units, while the theme's `radii.uiPanel` is in metres. [Theme fields](desktop-configuration.md#themes-and-appearance) lists which theme fields reach the UI. The [UI provider page](../../lua/lunette-plugins/ui/README.md) links its rendering specification.

A theme change keeps drafts, controls, and focus. A change of geometry, such as padding or radius, cancels held gestures; a change of colour alone does not.

A control's `draw` option is a hook that receives `(pass, visual, base)`. `visual` is a read-only snapshot of the control: logical `bounds`, `clip`, the resolved `theme` with its `font`, and the interaction state. Calling `base(pass, visual)` draws the default rendering, and not calling it replaces the drawing. A hook cannot change the bounds or clip that `base` receives.

A hook keeps its drawing inside `visual.clip`; the provider does not enforce the clip. The [UI rendering specification](../../lua/lunette-plugins/ui/docs/rendering.md) describes the drawing state, depth offsets, and pass cleanup.

## Ownership and replacement

Panel names are unique within one provider activation. A control's `id` is unique among the live controls of the owner that created it, so two owners can use the same id in one panel. The owner must be an active plugin bound to the provider. When the owner deactivates, or the provider is replaced or reloaded, its panels and controls die, and their surface offers, captures, and focus targets are released. A consumer checks `dead` before using a handle.

A control handle's `owner` identifies the owner activation that created it, as an opaque token compared by identity. An owner and an id together name one live control. `ui:inspect()` reports every live panel, control, and item with the geometry input uses, for the plugin manager and for tests that drive a panel they did not create. A panel's `revision` in that report changes whenever the panel changes within its activation.

## Decisions

Panels are inspected, not listed. A list of panel handles would give every plugin the methods of panels it did not create; `ui:inspect()` reports their geometry as data, which is what the plugin manager and the controller-driven tests read. A panel has no description method of its own, because a second view of the same geometry would only duplicate `ui:inspect()`.

Rounded panels clip their content to a conservative rectangle inside the outline. This keeps caller bounds unchanged and needs no stencil or offscreen pass, at the cost of some room near the corners. Controls keep rectangular hit areas, which are easier to hit than rounded ones, while the panel outline still excludes its corners. Custom hooks follow the clip by convention.

## Known gaps

The UI is a bounded toolkit for local VR controls. Text shaping, bidirectional editing, input methods, layout containers, and a general widget framework are outside the contract. Each panel and control caches up to 32 text layouts and 32 truncated labels; a long, changing draft can still cost quadratic measurement per frame.
