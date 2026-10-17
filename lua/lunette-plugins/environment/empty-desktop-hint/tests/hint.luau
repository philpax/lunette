local testing = require '@testing'
local panelsContract = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local expect = testing.expect

local test = testing.suite()

type Config = testing.ConfiguredInput<typeof(require('../').define)>
type Environment = {
  running: vrUi.Fixture,
  recorder: uiPanels.Recorder,
  host: uiHost.Service,
  panels: testing.Observed<panelsContract.Service>,
}

local PANEL = 'desktop/hint'

local function boot(config: Config?): Environment
  local recorder = uiPanels.new()
  local running = vrUi.boot {
    'frame',
    'theme',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'panels',
    recorder.entry,
    'ui-standard',
    { id = 'desktop/hint', definition = require('../').definition, config = config or {} },
  }
  running:step()
  local session = assert(running.session)
  return {
    running = running,
    recorder = recorder,
    host = assert(session:observe(uiHost.capability).service),
    panels = session:observe(panelsContract.capability),
  }
end

local function shown(env: Environment): boolean
  for _, registration in env.host:inspect().registrations do
    if registration.name == PANEL and registration.live then
      return registration.details.visible == true
    end
  end
  return false
end

local function window(env: Environment, id: number): panelsContract.WindowPanel
  local panels = env.panels
  local panel = assert(panels.service):fromWindow(assert(panels.context), env.running.native.newWindow(id), {})
  env.running:step()
  return panel
end

test('the empty scene shows the hint at its configured position with its text', function()
  local position = vector.pack(2, 3, -4)
  local env = boot { position = position, text = 'fixture hint', foreground = { 0.1, 0.2, 0.3, 1 } }
  expect.truthy(shown(env), 'the hint in the empty scene')
  local x, y, z = assert(env.recorder:panel(PANEL)):pose():getPosition()
  expect.near(x, position.x, 1e-5, 'the hint x position')
  expect.near(y, position.y, 1e-5, 'the hint y position')
  expect.near(z, position.z, 1e-5, 'the hint z position')
  local text = assert(env.recorder:node(PANEL, 'text'), 'the hint has its text node')
  expect.equal(text.props.text, 'fixture hint')
  expect.equal(text.props.color[3], 0.3, 'the configured foreground colours the text')
  env.running:close()
end)

test('a panel hides the hint, even a hidden one, and the hint returns once the last panel is gone', function()
  local env = boot()
  expect.equal(assert(env.recorder:node(PANEL, 'text')).props.text, 'lunette: no windows yet', 'the default text')
  local first = window(env, 1)
  expect.falsy(shown(env), 'a panel hides the hint')
  local second = window(env, 2)
  local context = assert(env.panels.context)
  first:setHidden(context, true)
  env.running:step()
  first:destroy(context)
  env.running:step()
  expect.falsy(shown(env), 'a panel remains, so the hint stays hidden')
  second:setHidden(context, true)
  env.running:step()
  expect.falsy(shown(env), 'a hidden panel still suppresses the hint')
  second:destroy(context)
  env.running:step()
  expect.truthy(shown(env), 'the hint returns with no panels left')
  env.running:close()
end)

return test
