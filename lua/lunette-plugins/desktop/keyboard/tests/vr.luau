local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local keyboard = require '@lunette-plugins/keyboard'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

local function board(service)
  for _, candidate in service:all() do
    if candidate.grabbable and candidate.setVisible then
      return candidate
    end
  end
  error 'the shared keyboard is not offered'
end

local function clickKey(running, current, kind)
  for _, key in current:keys() do
    if key.action and key.action.kind == kind then
      running:click({
        pose = current.pose,
        width = current.width,
        height = current.height,
        logicalWidth = current.width,
        logicalHeight = current.height,
        visible = current.visible,
      }, key.x + key.width / 2, key.y + key.height / 2, 'left')
      return
    end
  end
  error('the keyboard has no ' .. kind .. ' key')
end

for _, provider in { 'built-in', 'substitute' } do
  test(provider .. ' UI field clicks share one keyboard and user hide preserves its draft', function()
    local running = vrUi.boot {
      'frame',
      'theme',
      'surfaces',
      'drops',
      'focus',
      'interaction',
      {
        id = 'laser',
        definition = require('@lunette-plugins/laser').definition,
        config = { aim = { enabled = false }, triggerLock = { enabled = false } },
      },
      {
        id = 'keyboard',
        definition = keyboard.define {
          rows = {
            {
              { label = 'Insert', action = { kind = 'text', text = '!' } },
              { label = 'Hide', action = { kind = 'hide' } },
            },
          },
          layers = {},
        },
      },
      'desktop/pointing',
      if provider == 'built-in' then 'ui' else { id = 'ui', definition = require('@testing/ui-substitute').definition },
      'desktop/keyboard',
    }
    local state = {}
    running.session:use(
      plugin.define {
        name = 'testing/display-vr-fields',
        requires = { ui = ui.capability },
        init = function(owner)
          state.service = owner:require(ui.capability)
          local panel = state.service:newPanel(owner, {
            name = 'Shared keyboard fields',
            pose = lovr.math.newMat4():translate(0, 1.5, -2),
            width = 1,
            height = 1,
            logicalWidth = 200,
            logicalHeight = 200,
          })
          state.first = panel:textField(owner, {
            id = 'first',
            value = 'draft',
            bounds = { x = 10, y = 10, width = 180, height = 30 },
          })
          state.second = panel:textField(owner, {
            id = 'second',
            bounds = { x = 10, y = 60, width = 180, height = 30 },
          })
        end,
      },
      {}
    )
    local routes = running.session:observe(focus.capability)
    local shown = running.session:observe(display.capability)
    local offers = running.session:observe(surfaces.capability)
    expect.equal(running:keyboardCount(), 0, 'the display starts without a board')
    running:clickControl(state.service, 'Shared keyboard fields', 'first')
    local current = board(offers.service)
    expect.equal(running:keyboardCount(), 1, 'field interaction creates one keyboard')
    clickKey(running, current, 'text')
    expect.equal(state.first:value(), 'draft!', 'the left controller types into the right-selected field')
    current:setPose(lovr.math.newMat4():translate(0, 0.8, -1))
    running:clickControl(state.service, 'Shared keyboard fields', 'second')
    expect.equal(board(offers.service), current, 'field switching reuses the board')
    expect.equal(vector.pack(current.pose:getPosition()), vector.pack(0, 0.8, -1), 'field switching retains placement')
    running:clickControl(state.service, 'Shared keyboard fields', 'first')
    clickKey(running, current, 'hide')
    expect.equal(routes.service:focused(), nil, 'the keyboard Hide control ends editing')
    expect.falsy(shown.service:isVisible())
    expect.equal(state.first:value(), 'draft!', 'hiding preserves the draft')
    running:clickControl(state.service, 'Shared keyboard fields', 'first')
    expect.equal(board(offers.service), current, 'a fresh click resumes on the same board')
    expect.equal(running:keyboardCount(), 1, 'no second desktop keyboard is created')
    state.service:panels()[1]:destroy()
    running:step()
    expect.equal(routes.service:focused(), nil, 'field removal ends its route')
    expect.falsy(shown.service:isVisible(), 'field removal ends automatic visibility')
    expect.equal(running:keyboardCount(), 1, 'the hidden board remains reusable')
    running:close()
  end)
end

return test
