local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local wristMenu = require '@testing/wrist-menu'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'

type Session = testing.Session
type Native = testing.Native
type Board = desktop.Keyboard
type Environment = {
  fixture: vrUi.Fixture,
  recorder: uiPanels.Recorder,
  session: Session,
  native: Native,
  ui: ui.Service,
  menu: menu.Service,
  display: display.Service,
  surfaces: surfaces.Service,
}

local test = testing.suite()
local name = 'example/ui/form'
local actionId = 'example/ui/open'

local function description(service: ui.Service): vrUi.Description?
  return vrUi.describe(service, name)
end

local function boot(): Environment
  testing.host.useConfiguration 'examples/ui'
  local recorder = uiPanels.new()
  local patches = {
    { id = 'ui-host', definition = recorder.definition },
    { insert = { id = name, definition = require('form').definition } },
  }
  local fixture = vrUi.boot(desktop.compose { patches = patches })
  local session = fixture.session
  local env = {
    fixture = fixture,
    recorder = recorder,
    session = session,
    native = fixture.native,
    ui = session:observe(ui.capability).service,
    menu = session:observe(menu.capability).service,
    display = session:observe(display.capability).service,
    surfaces = session:observe(surfaces.capability).service,
  }
  fixture:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  fixture:tracked('left', true)
  fixture:step()
  return env
end

local function withEnvironment(run: (Environment) -> ())
  local env = boot()
  run(env)
  env.fixture:close()
end

local function click(env: Environment, id: string, itemId: string?, hand: vrUi.Hand?)
  env.fixture:clickControl(env.ui, name, id, hand or 'right', itemId)
end

local function open(env: Environment)
  wristMenu.run(env.fixture, env.recorder, actionId)
end

local function key(env: Environment, code: number)
  local board: Board?
  for _, candidate in env.surfaces:all() do
    if candidate.keys and candidate.setVisible then
      assert(board == nil, 'one shared keyboard is offered')
      board = candidate
    end
  end
  assert(board and board.visible, 'the shared keyboard is visible')
  board:setPose(lovr.math.newMat4():translate(0, 0.6, -0.8))
  for _, current in board:keys() do
    if current.code == code then
      env.fixture:click({
        pose = board.pose,
        width = board.width,
        height = board.height,
        logicalWidth = board.width,
        logicalHeight = board.height,
        visible = board.visible,
      }, current.x + current.width / 2, current.y + current.height / 2, 'left')
      return
    end
  end
  error('missing shared keyboard code ' .. tostring(code))
end

local function status(env: Environment): string
  env.native.events.draw = {}
  env.fixture:draw()
  for _, call in env.native.events.draw do
    if call[1] == 'text' and type(call[2]) == 'string' and call[2]:find('Presses:', 1, true) then
      return call[2]
    end
  end
  error 'the custom region does not draw its status'
end

test('the UI configuration boots and draws through the shipped desktop', function()
  local native = testing.native()
  testing.host.useConfiguration 'examples/ui'
  require 'main'
  lovr.load()
  lovr.update(0.016)
  expect.equal(lovr.draw(native.events.pass), false, 'the example does not veto drawing')
  expect.equal(lovr.quit(), false, 'the example does not veto normal quit')
  native.assertResourcesReleased()
end)

test('the form opens from the wrist menu and completes its workflow by controller', function()
  withEnvironment(function(env: Environment)
    expect.falsy(assert(description(env.ui)).visible, 'the form starts hidden')
    open(env)
    expect.truthy(assert(description(env.ui)).visible, 'the wrist action opens the form')
    click(env, 'press')
    expect.truthy(status(env):find('Presses: 1', 1, true), 'the button invokes the consumer callback')
    click(env, 'name')
    expect.truthy(env.display:isVisible(), 'the field requests the shared keyboard')
    key(env, 16)
    expect.truthy(status(env):find('name: q', 1, true), 'a VR key edits the form text')
    click(env, 'mode')
    click(env, 'mode', 'studio')
    expect.truthy(status(env):find('mode: studio', 1, true), 'the choice invokes the consumer callback')
    click(env, 'preview')
    expect.truthy(status(env):find('taps: 1', 1, true), 'the custom region receives a pointer gesture')
    click(env, 'close')
    expect.falsy(assert(description(env.ui)).visible, 'Close hides the form')
    expect.falsy(env.display:isVisible(), 'Close ends the keyboard claim')
  end)
end)

return test
