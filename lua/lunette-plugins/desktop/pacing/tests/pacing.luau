-- Covers the desktop pacing consumer over the panels in the scene: a hidden panel's window falls to the floor
-- rate and a hidden monitor panel's capture pauses, and each returns when its panel is shown again, when its
-- panel is removed, when the consumer or the pacing provider unloads, and when the runtime closes. The pacer's
-- own decisions are covered by `pacing/tests/pacer.luau`.
local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

-- The consumer over the fake native API, with a quiet window and a monitor, each shown as a panel.
local function start()
  local env = {}
  env.session = testing.boot { 'frame', 'surfaces', 'panels', 'pacing', 'desktop/pacing' }
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

test('a hidden panel is paced at the floor and a shown one is unthrottled again', function()
  local env = start()
  for _ = 1, 5 do
    env.session:update()
  end
  expect.equal(#env.native.events.rates, 0, 'the rates applied to a shown window')
  expect.equal(#env.native.events.pauses, 0, 'the pauses of a shown monitor panel')

  hide(env, true)
  expect.equal(env.window.rate, 1, 'a hidden quiet window')
  expect.equal(env.monitor.paused, true, 'the capture of a hidden monitor panel')

  hide(env, false)
  expect.equal(env.window.rate, nil, 'a shown window')
  local rates = env.native.events.rates
  expect.equal(rates[#rates].window, env.window.id, 'the window the last rate was applied to')
  expect.equal(env.monitor.paused, false, 'the capture of a shown monitor panel')
  env.session:close()
end)

test('unloading the consumer unthrottles and resumes everything, and loading again paces again', function()
  local env = start()
  hide(env, true)
  local consumer = env.session.instances['desktop/pacing']
  consumer:disable()
  expect.equal(env.window.rate, nil, 'a window after the consumer unloads')
  expect.equal(env.monitor.paused, false, 'a capture after the consumer unloads')
  local unloaded = #env.native.events.rates
  env.session:update()
  expect.equal(#env.native.events.rates, unloaded, 'the rates an unloaded consumer applies')

  consumer:enable()
  env.session:update()
  expect.equal(env.window.rate, 1, 'a hidden window once the consumer loads again')
  expect.equal(env.monitor.paused, true, 'a hidden capture once the consumer loads again')
  env.session:close()
  expect.equal(env.monitor.paused, false, 'a capture after the runtime closes')
end)

test('a pacing provider outage unthrottles, and the consumer paces again when it returns', function()
  local env = start()
  hide(env, true)
  local provider = env.session.instances.pacing
  provider:disable()
  expect.equal(env.window.rate, nil, 'a window during the outage')
  expect.equal(env.monitor.paused, false, 'a capture during the outage')
  provider:enable()
  env.session:update()
  expect.equal(env.window.rate, 1, 'a hidden window after the outage')
  env.session:close()
end)

test('a window whose panel is removed is unthrottled', function()
  local env = start()
  hide(env, true)
  env.windowPanel:destroy(env.panels.context)
  env.session:update()
  expect.equal(env.window.rate, nil, 'a window without a panel')
  expect.equal(env.monitor.paused, true, 'a monitor panel still hidden keeps its pause')
  env.session:close()
end)

return test
