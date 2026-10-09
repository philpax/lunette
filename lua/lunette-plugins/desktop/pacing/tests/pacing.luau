local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

-- The consumer over the fake native API, with a quiet window and a monitor, each shown as a panel.
local function start()
  local env = {}
  env.session = testing.boot { 'frame', 'theme', 'surfaces', 'panels', 'pacing', 'desktop/pacing' }
  env.native = env.session.native
  env.panels = env.session:observe(panelsContract.capability)
  env.window = env.native.newWindow(1)
  env.monitor = env.native.newMonitor 'DP-1'
  env.windowPanel = env.panels.service:fromWindow(env.panels.context, env.window, {})
  env.monitorPanel = env.panels.service:fromMonitor(env.panels.context, env.monitor, {})
  return env
end

local function hide(env, hidden)
  env.windowPanel:setHidden(env.panels.context, { hidden = hidden })
  env.monitorPanel:setHidden(env.panels.context, { hidden = hidden })
  env.session:update()
end

test('a hidden panel is paced at the floor, a shown one is not, and unloading releases both', function()
  local env = start()
  env.session:update()
  expect.equal(#env.native.events.rates, 0, 'the rates applied to a shown window')
  expect.equal(#env.native.events.pauses, 0, 'the pauses of a shown monitor panel')
  hide(env, true)
  expect.equal(env.window.rate, 1, 'a hidden quiet window')
  expect.equal(env.monitor.paused, true, 'the capture of a hidden monitor panel')
  hide(env, false)
  expect.equal(env.window.rate, nil, 'a shown window')
  expect.equal(env.monitor.paused, false, 'the capture of a shown monitor panel')
  hide(env, true)
  env.session.instances['desktop/pacing']:disable()
  expect.equal(env.window.rate, nil, 'a window after the consumer unloads')
  expect.equal(env.monitor.paused, false, 'a capture after the consumer unloads')
  env.session:close()
end)

return test
