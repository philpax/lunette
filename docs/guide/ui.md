# UI panels

`@lunette-contracts/ui` declares `lunette/ui` at schema 1. The service creates owner-scoped flat VR panels with buttons, single-line text fields, choices, lists, and custom regions. `lua/lunette-contracts/ui.luau` is the source of truth for the public types. `@lunette-plugins/ui` implements the contract and requires focus and surfaces. Consumers import the contract rather than the provider's internal modules.

## A public-contract fixture

A consumer creates a panel with its context as the owner and draws that panel through an owner-scoped frame handler. The provider offers the panel as a surface, but does not register a frame drawing order. A configuration must include a UI provider and the frame, focus, and surfaces providers that the composition requires.

```luau
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local ui = require '@lunette-contracts/ui'

return plugin.define {
  name = 'ui-fixture',
  requires = { ui = ui.capability, frame = frame.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
    local service: ui.Service = context:require(ui.capability)
    local frames: frame.Service = context:require(frame.capability)
    local panel = service:newPanel(context, {
      name = 'ui-fixture',
      width = 0.6,
      height = 0.2,
      logicalWidth = 600,
      logicalHeight = 200,
    })
    local query = panel:textField(context, {
      id = 'query',
      label = 'Query',
      bounds = { x = 12, y = 12, width = 400, height = 40 },
      value = '',
    })
    panel:button(context, {
      id = 'clear',
      label = 'Clear',
      bounds = { x = 424, y = 12, width = 160, height = 40 },
      onActivate = function(): ()
        if not query.dead then
          query:setValue('')
        end
      end,
    })
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass): ()
        if not panel.dead then
          panel:draw(pass)
        end
      end,
    })
  end,
}
```

The strict fixture in `crates/lunette/tests/luau_check/ui/widgets_positive.luau` exercises this public-contract pattern. It is a type-check fixture, not an XR acceptance example. A checked configuration under `examples/ui` remains pending. No menu contract is part of this example, and the shipped desktop controls and runtime manager have not yet migrated to the UI service.

## Geometry and input

`width` and `height` are world-space metres. `logicalWidth` and `logicalHeight` define the panel's logical coordinate space. Logical coordinates start at the top-left corner, with x increasing rightward and y increasing downward. Bounds use half-open intervals: the left and top edges are inside, and the right and bottom edges are outside. Bounds and dimensions must be finite. Panel dimensions must be positive. Control widths and heights may be zero; zero-area controls do not receive input.

The same declared bounds determine pointer input, drawing, and `panel:describe()`. Controls and item bounds are clipped to the panel. A higher `z` wins overlapping input; later registration wins a tie. A custom region declares item bounds and optional routes explicitly. Drawing a larger shape does not enlarge a control's input bounds.

Each pointer button captures its original control until release or cancellation. Leaving a control does not transfer a held gesture to another control. Hiding a panel, disabling or destroying a control, changing a panel's size, or replacing control bounds or items cancels the affected gesture without activating it. `Panel:setPose` preserves captures during rigid motion and updates projected coordinates. Beginning a grip-driven grab cancels pointer gestures before motion. An exclusive control excludes another pointer while captured. Hover does not change keyboard focus. Text fields use local focus targets, and a region requests keyboard routing explicitly through its receiver and `wantsKeyboard` options.

## Text fields

Text fields accept valid single-line Unicode UTF-8. Control characters and line separators are rejected. `setSelection(caret, anchor?)` uses one-based UTF-8 byte offsets at extended grapheme boundaries. Omitting the anchor collapses the selection. The empty string has boundary `{ 1 }`, and every non-empty boundary list includes the terminal offset `#value + 1`. A selected range excludes its terminal boundary. Movement, deletion, selection, truncation, and insertion preserve whole grapheme clusters, including combining marks and emoji sequences.

`lunette.textBoundaries(text)` supplies these boundaries through the native Unicode segmentation implementation. It returns a fresh array and rejects invalid UTF-8. It does not provide shaping, bidirectional layout, or an IME or preedit protocol. The default renderer measures and draws with the same LÖVR font. It shows clipping or overflow explicitly rather than silently displaying a partial grapheme.

`onChange`, `onSubmit`, and `onCancel` receive the current string. Escape blurs before `onCancel` runs. Widget callback failures produce one owner-labelled report without undoing a committed draft or blur; the valid key or text operation remains consumed. Raw region receiver failures produce a failed focus-source result and never reach an application. `validate` returns an error string or nil. `setError` can present an external validation error. Focus sources deliver physical committed text and virtual key activations through the focus contract; the UI service does not bypass that routing with direct native sink delivery.

## Themes and drawing hooks

The built-in provider accepts `theme` overrides and a `draw` hook. Panels and controls accept narrower overrides of the same types. Resolution applies provider, panel, and control overrides in that order. A colour list replaces the complete colour value. `setTheme(nil)` removes an object's override and restores its inherited theme.

A draw hook receives `(pass, visual, base)`. The visual is an immutable snapshot with logical bounds, clipping bounds, the resolved theme, interaction state, and widget data. The provider hook wraps the default renderer, the panel hook wraps the provider renderer, and the control hook wraps the panel renderer. Calling `base(pass, visual)` preserves the wrapped renderer; omitting it replaces the drawing. A hook can change appearance, but cannot alter declared bounds or clipping bounds passed to `base`.

Hooks draw in logical panel coordinates beneath the panel-to-world transform. Custom geometry must stay within `visual.clip`. The renderer restores the pass state and transform around each invocation, including when a hook raises. A hook must balance its own stack pushes, must not pop a stack entry it does not own, and must not retain the pass for later use. Arbitrary pass misuse is outside the restoration guarantee. Errors continue to the surrounding frame error boundary.

## Ownership and replacement

Panel names are unique within one provider activation. Control ids are unique across all live panels for the actual owner passed to the control's creation method. Different owners can reuse an id within the same panel; one owner cannot reuse it in another live panel until the earlier control ends. Panel ownership does not replace the control's creation owner. The owner must be live and bound to the provider. Owner unload, provider replacement, and source reload invalidate handles and release their surface offers, captures, and control-held focus resources. A callback retained from an ended activation must not affect a replacement panel.

The UI provider registers the underlying focus target under its own context. The control's owner-held inverse releases that target, so its lifetime follows the control. Cleanup attempts the remaining releases and rethrows failures rather than swallowing them. A failure raised during control-owner cleanup remains visible at that owner's inverse boundary; direct destruction raises it to the caller. Receiver errors are annotated with the control owner's label and rethrown to the focus delivery boundary. This does not change the underlying focus target's registration owner to the control owner.

`panel:describe()` returns a detached read-only snapshot. `description.generation` is a frozen `ui.Generation` token shared by panels from one provider activation. A replacement activation creates a different token, even when it reuses the same panel names and control ids. Each control handle and control description carries a read-only `owner` field containing a frozen `ui.OwnerIdentity` token. That token is stable for one owner activation within the UI provider and changes after an owner or provider replacement. It exposes no context, methods, or scripting authority.

The generation token, owner token, and control id together disambiguate a live control. An id alone is insufficient because different owners can reuse it in the same panel. Tokens are compared by reference identity; their `kind` fields are discriminators, not activation identifiers. `description.revision` tracks changes within the panel's activation. Consumers discard cached handles and descriptions when the relevant token changes and check a handle's `dead` field before use.

## Known gaps

The copied-install checker and module-load regressions cover both feature sets through the custom test runner and installed manifest roots. They do not exercise LÖVR's production virtual-filesystem mounting or an installed session boot. GPU-backed drawing and in-headset workflows remain separate acceptance gates.

The UI service is a bounded toolkit for local VR controls. Menu composition, desktop control migration, runtime manager migration, and a checked `examples/ui` configuration remain follow-up work. Full text shaping, bidirectional editing, IME composition, general layout containers, and a complete desktop widget framework are outside the current contract. The built-in renderer caches 32 recent text layouts and 32 label truncation results per font without retaining the font. Unchanged cached results avoid repeated substring measurement, but cold misses and cache churn still perform exhaustive searches with worst-case quadratic measured-text work. Long changing drafts have no verified frame-time bound. GPU-backed drawing and in-headset acceptance remain unverified by the type-check fixtures.
