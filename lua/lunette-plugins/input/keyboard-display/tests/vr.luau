local testing = require '@testing'
local expect = testing.expect
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local keyboard = require '@lunette-plugins/input/keyboard'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local fields = require './support/fields'
local test = testing.suite()

type Board = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read visible: boolean,
  read keys: (Board) -> { keyboard.RenderedKey },
}
type Environment = {
  running: vrUi.Fixture,
  panels: uiPanels.Recorder,
  fields: fields.Fields,
  focus: focus.Service,
  display: display.Service,
  surfaces: surfaces.Service,
}

local FIELDS = 'Shared keyboard fields'
local TITLEBAR = 'desktop/keyboard/titlebar'

local function boot(): Environment
  local panels = uiPanels.new()
  local state = fields.new()
  local running = vrUi.boot {
    'frame',
    'theme',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    {
      id = 'laser',
      definition = require('@lunette-plugins/input/laser').definition,
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
    panels.entry,
    'ui-standard',
    { id = 'desktop/keyboard', definition = require('../').definition },
    {
      id = 'fields',
      definition = fields.definition(state, { name = FIELDS, pose = lovr.math.newMat4():translate(0, 1.5, -2) }),
    },
  }
  local session = assert(running.session)
  running:step()
  return {
    running = running,
    panels = panels,
    fields = state,
    focus = assert(session:observe(focus.capability).service),
    display = assert(session:observe(display.capability).service),
    surfaces = assert(session:observe(surfaces.capability).service),
  }
end

local function board(service: surfaces.Service): Board
  for _, candidate in service:all() do
    if candidate.grabbable and candidate.setVisible then
      return candidate
    end
  end
  error 'the shared keyboard is not offered'
end

local function clickKey(running: vrUi.Fixture, current: Board, kind: string)
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

local function position(pose: Mat4): vector
  return vector.pack(pose:getPosition())
end

test('controller clicks on fields share one keyboard that types, and its Hide key keeps the draft', function()
  local env = boot()
  local running = env.running
  expect.equal(running:keyboardCount(), 0, 'the display starts without a board')
  env.panels:click(running, FIELDS, 'body/first')
  local current = board(env.surfaces)
  expect.equal(running:keyboardCount(), 1, 'field interaction creates one keyboard')
  clickKey(running, current, 'text')
  expect.equal(env.fields.values.first, 'draft!', 'the left controller types into the right-selected field')
  env.panels:click(running, FIELDS, 'body/second')
  expect.equal(board(env.surfaces), current, 'field switching reuses the board')
  clickKey(running, current, 'hide')
  expect.equal(env.focus:focused(), nil, 'the keyboard Hide control ends editing')
  expect.falsy(env.display:isVisible())
  expect.equal(env.fields.values.first, 'draft!', 'hiding preserves the draft')
  env.panels:click(running, FIELDS, 'body/first')
  expect.equal(board(env.surfaces), current, 'a fresh click resumes on the same board')
  expect.equal(running:keyboardCount(), 1, 'no second desktop keyboard is created')
  running:close()
end)

test('the titlebar sits above the keyboard and closes it', function()
  local env = boot()
  local running = env.running
  env.panels:click(running, FIELDS, 'body/first')
  local current = board(env.surfaces)
  running:step()
  local bar = assert(env.panels:panel(TITLEBAR), 'the shown keyboard has a titlebar')
  expect.truthy(env.panels:node(TITLEBAR, 'header'), 'the titlebar names the keyboard')
  local width, height = bar:size()
  expect.truthy(width >= current.width - 1e-5, 'the titlebar spans the keyboard, and grows past a narrow one to fit')
  local above = lovr.math.newMat4(current.pose):invert() * bar:pose()
  local x, y, z = above:getPosition()
  expect.near(x, 0, 1e-5, 'the titlebar is centred on the keyboard')
  expect.truthy(y > current.height / 2 + height / 2 - 1e-5, 'the titlebar sits above the keyboard')
  expect.truthy(math.abs(z) < 0.001, 'the titlebar lies in the keyboard plane')
  local host = assert(running.session):observe(require('@lunette-contracts/ui-host').capability)
  local theme = assert(running.session):observe(require('@lunette-contracts/theme').capability)
  assert(theme.service):setMode 'light'
  running:step()
  expect.equal(assert(env.panels:node(TITLEBAR, 'header')).theme.mode, 'light', 'the mounted titlebar restyles')

  env.panels:click(running, TITLEBAR, 'header/band/close')
  expect.falsy(env.display:isVisible(), 'Close hides the keyboard')
  expect.equal(env.focus:focused(), nil, 'Close ends editing')
  expect.equal(env.fields.values.first, 'draft', 'Close keeps the field text')
  for _, registration in assert(host.service):inspect().registrations do
    if registration.name == TITLEBAR then
      expect.falsy(registration.details.visible, 'the titlebar hides with the keyboard')
    end
  end
  running:close()
end)

test('a trigger drag on the titlebar carries the keyboard', function()
  local env = boot()
  local running = env.running
  env.panels:click(running, FIELDS, 'body/first')
  local current = board(env.surfaces)
  running:step()
  local bar = assert(env.panels:panel(TITLEBAR), 'the shown keyboard has a titlebar')
  local width = bar:size()
  -- The drag starts on the bar's empty space, left of its title.
  local px, py, pz = position(current.pose).x, position(current.pose).y, position(current.pose).z
  local origin = lovr.math.newMat4(bar:pose()):translate(-width / 2 + 0.005, 0, 0.5)
  running:pose('right', origin)
  running:tracked('right', true)
  running:step()
  running:button('right', 'trigger', true)
  running:step()
  local destination = lovr.math.newMat4(origin):translate(0.3, 0.1, -0.1)
  running:pose('right', destination)
  running:step()
  running:button('right', 'trigger', false)
  running:step()
  -- The keyboard follows the controller's displacement in the world.
  local delta = position(destination) - position(origin)
  local moved = position(current.pose)
  expect.near(moved.x, px + delta.x, 1e-4, 'the keyboard moves in x')
  expect.near(moved.y, py + delta.y, 1e-4, 'the keyboard moves in y')
  expect.near(moved.z, pz + delta.z, 1e-4, 'the keyboard moves in z')

  running:close()
end)

return test
