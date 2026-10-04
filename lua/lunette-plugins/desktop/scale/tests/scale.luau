local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local function start()
  local env = {}
  env.session = testing.boot { 'frame', 'surfaces', 'panels', 'scale', 'desktop/scale' }
  env.native = env.session.native
  env.panels = env.session:observe(panelsContract.capability)
  env.primary = env.native.events.outputs[1]
  env.secondary = env.native.newOutput(2, 1)
  env.native.events.outputs[2] = env.secondary
  return env
end

local function windowAt(env, id, output, distance)
  local window = env.native.newWindow(id)
  window.output = output
  local panel = env.panels.service:fromWindow(env.panels.context, window, {})
  panel:setPose(lovr.math.newMat4(0, 1.5, -distance))
  return panel
end

local function modesOf(env, output)
  local count = 0
  for _, mode in ipairs(env.native.events.modes) do
    if mode.output == output.id then
      count += 1
    end
  end
  return count
end

test('the nearest window panel sets its own output only, and a monitor panel is no output', function()
  local env = start()
  windowAt(env, 1, env.primary, 0.5)
  windowAt(env, 2, env.primary, 3)
  windowAt(env, 3, env.secondary, 2)
  local monitor = env.panels.service:fromMonitor(env.panels.context, env.native.newMonitor 'DP-1', {})
  monitor:setPose(lovr.math.newMat4(0, 1.5, -0.1))
  env.session:update()
  expect.equal(env.primary.scale, 2, 'the output of the panel half a metre away')
  expect.equal(modesOf(env, env.primary), 1, 'the changes to the nearer output')
  expect.equal(modesOf(env, env.secondary), 0, 'the changes to the output of the far panel')
  env.session:close()
end)

test('a hidden panel gives no distance, so the next nearest decides', function()
  local env = start()
  local near = windowAt(env, 1, env.primary, 0.5)
  windowAt(env, 2, env.primary, 3)
  env.session:update()
  expect.equal(env.primary.scale, 2, 'the output while the near panel is shown')
  near:setHidden(env.panels.context, { hidden = true })
  env.session:update()
  expect.equal(env.primary.scale, 1, 'the output while the near panel is hidden')
  near:setHidden(env.panels.context, { hidden = false })
  env.session:update()
  expect.truthy(env.primary.scale > 1, 'the output once the near panel is shown again')
  env.session:close()
end)

test('unloading restores the original scale and sets nothing afterwards', function()
  local env = start()
  windowAt(env, 1, env.primary, 0.5)
  env.session:update()
  expect.equal(env.primary.scale, 2, 'the scale the consumer set')
  env.session.instances['desktop/scale']:disable()
  expect.equal(env.primary.scale, 1, 'the scale after unloading')
  local unloaded = #env.native.events.modes
  env.session:update()
  expect.equal(#env.native.events.modes, unloaded, 'the changes an unloaded consumer makes')
  env.session:close()
end)

test('a scale something else set is left alone on unload', function()
  local env = start()
  windowAt(env, 1, env.primary, 0.5)
  env.session:update()
  env.primary:setMode { scale = 1.5 }
  env.session.instances['desktop/scale']:disable()
  expect.equal(env.primary.scale, 1.5, 'the scale another plugin set')
  env.session:close()
end)

return test
