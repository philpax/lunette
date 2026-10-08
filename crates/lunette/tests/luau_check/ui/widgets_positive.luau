local ui = require '@lunette-contracts/ui'
local frame = require '@lunette-contracts/frame'
local plugin = require '@lunette-plugin'

local function draw(pass: Pass, visual: ui.Visual, base: ui.Renderer): ()
  local x: number = visual.bounds.x
  local font: Font = visual.theme.font
  local panelRadius: number = visual.theme.panelRadius
  local controlRadius: number = visual.theme.controlRadius
  assert(x == x and panelRadius >= 0 and controlRadius >= 0 and font ~= nil)
  base(pass, visual)
end

local function create(service: ui.Service, owner: ui.Owner): ui.Panel
  local panel = service:newPanel(owner, {
    name = 'public-ui-fixture',
    width = 0.6,
    height = 0.3,
    logicalWidth = 600,
    logicalHeight = 300,
    theme = {
      control = { 0.2, 0.3, 0.4, 1 },
      font = { kind = 'file', file = 'fixture.ttf', size = 24, spread = 4 },
      panelRadius = 0,
      controlRadius = 3,
    },
    draw = draw,
  })
  local button: ui.Button = panel:button(owner, {
    id = 'apply',
    label = 'Apply',
    bounds = { x = 12, y = 12, width = 120, height = 40 },
    onActivate = function(): () end,
  })
  local field: ui.TextField = panel:textField(owner, {
    id = 'query',
    bounds = { x = 12, y = 64, width = 400, height = 40 },
    value = '',
    onChange = function(value: string): ()
      assert(#value >= 0)
    end,
    onSubmit = function(value: string): ()
      assert(#value >= 0)
    end,
    onCancel = function(value: string): ()
      assert(#value >= 0)
    end,
    validate = function(value: string): string?
      return if value == '' then 'A value is required' else nil
    end,
  })
  local choice: ui.Choice = panel:choice(owner, {
    id = 'mode',
    bounds = { x = 12, y = 116, width = 160, height = 40 },
    items = { { id = 'compact', label = 'Compact' }, { id = 'full', label = 'Full', enabled = true } },
    selected = 'compact',
    onChange = function(id: string): ()
      assert(id ~= '')
    end,
  })
  local list: ui.List = panel:list(owner, {
    id = 'results',
    bounds = { x = 184, y = 116, width = 220, height = 100 },
    items = { { id = 'first', label = 'First' } },
  })
  local region: ui.Region = panel:region(owner, {
    id = 'diagram',
    bounds = { x = 420, y = 12, width = 160, height = 204 },
    items = { { id = 'node', bounds = { x = 430, y = 24, width = 40, height = 40 } } },
  })
  button:setEnabled(true)
  field:setValue 'query'
  field:setSelection(1)
  local caret: number, anchor: number = field:selection()
  choice:setSelected 'full'
  list:setSelected(nil)
  region:setItems {}
  assert(caret >= 1 and anchor >= 1)
  return panel
end

local fixture = plugin.define {
  name = 'public-ui-fixture',
  requires = { ui = ui.capability, frame = frame.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
    local service: ui.Service = context:require(ui.capability)
    local frames: frame.Service = context:require(frame.capability)
    local panel = create(service, context)
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

return { fixture = fixture, create = create }
