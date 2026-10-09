local ui = require '@lunette-contracts/ui'
local vocabulary = require '@lunette-contracts/vocabulary'

local bounds: ui.Bounds = { x = 0, y = 0, width = 100, height = 40 }

local function misuse(panel: ui.Panel, owner: ui.Owner, field: ui.TextField, choice: ui.Choice): ()
  local wrongBounds: ui.Bounds = { x = 'left', y = 0, width = 100, height = 40 } -- reject.
  local wrongTheme: ui.ThemeOverrides = { fontSize = 'large' } -- reject.
  local wrongFont: ui.ThemeOverrides = { font = lovr.graphics.getDefaultFont() } -- reject.
  local missingFontFields: ui.ThemeOverrides = { font = { kind = 'file', file = 'fixture.ttf' } } -- reject.
  local wrongRadius: ui.ThemeOverrides = { panelRadius = 'round' } -- reject.
  assert(wrongFont.font ~= nil and missingFontFields.font ~= nil and wrongRadius.panelRadius ~= nil)
  local wrongItem: ui.Item = { id = 'item', label = 'Item', enabled = 'yes' } -- reject.
  local activate: () -> () = function(_value: string): () end -- reject.
  local change: (string) -> () = function(_value: number): () end -- reject.
  local wrongValidator = function(_value: string): number
    return 1
  end
  local validate: (string) -> string? = wrongValidator -- reject.
  local hook: ui.DrawHook = function(_pass: Pass, _visual: ui.Description, _base: ui.Renderer): () end -- reject.
  local pointer: (vocabulary.PointerEvent) -> () = function(_event: string): () end -- reject.
  panel:button(owner, { id = 'button', bounds = bounds, onActivate = function(_value: string): () end }) -- reject.
  panel:textField(owner, { id = 'field', bounds = bounds, value = 1 }) -- reject.
  local numberCallback = function(_value: number): () end
  panel:textField(owner, { id = 'field-change', bounds = bounds, onChange = numberCallback }) -- reject.
  panel:textField(owner, { id = 'field-submit', bounds = bounds, onSubmit = numberCallback }) -- reject.
  panel:textField(owner, { id = 'field-cancel', bounds = bounds, onCancel = numberCallback }) -- reject.
  local numberValidator = function(_value: number): string?
    return nil
  end
  panel:textField(owner, { id = 'field-validate', bounds = bounds, validate = numberValidator }) -- reject.
  panel:choice(owner, {
    id = 'choice',
    bounds = bounds,
    items = {},
    selected = false, -- reject.
    onChange = function(): () end,
  })
  panel:list(owner, { id = 'list', bounds = bounds, items = { { id = 'item', label = false } } }) -- reject.
  panel:region(owner, { id = 'region', bounds = bounds, wantsKeyboard = 'yes' }) -- reject.
  field:setSelection 'start' -- reject.
  choice:setItems { { id = false, label = 'Item' } } -- reject.
  assert(wrongBounds.x >= 0 and wrongTheme.fontSize ~= nil and wrongItem.id ~= '')
  activate()
  change 'value'
  assert(validate 'value' ~= nil)
  assert(hook ~= nil and pointer ~= nil)
end

return misuse
