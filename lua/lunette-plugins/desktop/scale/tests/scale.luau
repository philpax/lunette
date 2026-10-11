local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'

type Native = typeof(require '@testing/native')
type Sessions = typeof(require '@testing/session')
type Environment = {
  session: Sessions.Session,
  native: Native.Fake,
  panels: Sessions.Observed<panelsContract.Service>,
  primary: Native.Output,
  secondary: Native.Output,
}

local test = testing.suite()

local function start(): Environment
  local env: Environment = {}
  env.session = testing.boot { 'frame', 'theme', 'surfaces', 'panels', 'scale', 'desktop/scale' }
  env.native = env.session.native
  env.panels = env.session:observe(panelsContract.capability)
  env.primary = env.native.events.outputs[1]
  env.secondary = env.native.newOutput(2, 1)
  env.native.events.outputs[2] = env.secondary
  return env
end

local function windowAt(
  env: Environment,
  id: number,
  output: Native.Output,
  distance: number
): panelsContract.WindowPanel
  local window = env.native.newWindow(id)
  window.output = output
  local panel = env.panels.service:fromWindow(env.panels.context, window, {})
  panel:setPose(lovr.math.newMat4(0, 1.5, -distance))
  return panel
end

local function modesOf(env: Environment, output: Native.Output): number
  local count = 0
  for _, mode in ipairs(env.native.events.modes) do
    if mode.output == output.id then
      count += 1
    end
  end
  return count
end

test(
  'the nearest shown window panel sets its own output only, and hidden and monitor panels give no distance',
  function()
    local env = start()
    windowAt(env, 1, env.primary, 0.5)
    windowAt(env, 2, env.primary, 3)
    windowAt(env, 3, env.secondary, 2)
    local monitor = env.panels.service:fromMonitor(env.panels.context, env.native.newMonitor 'DP-1', {})
    monitor:setPose(lovr.math.newMat4(0, 1.5, -0.1))
    local hidden = windowAt(env, 4, env.secondary, 0.2)
    hidden:setHidden(env.panels.context, true)
    env.session:update()
    expect.equal(env.primary.scale, 2, 'the output of the panel half a metre away')
    expect.equal(modesOf(env, env.secondary), 0, 'the changes to the output of the far and hidden panels')
    env.session:close()
  end
)

test('unloading restores the original scale, unless something else set it', function()
  local env = start()
  windowAt(env, 1, env.primary, 0.5)
  env.session:update()
  env.session.instances['desktop/scale']:disable()
  expect.equal(env.primary.scale, 1, 'the scale after unloading')
  env.session.instances['desktop/scale']:enable()
  env.session:update()
  env.primary:setMode { scale = 1.5 }
  env.session.instances['desktop/scale']:disable()
  expect.equal(env.primary.scale, 1.5, 'the scale another plugin set')
  env.session:close()
end)

return test
