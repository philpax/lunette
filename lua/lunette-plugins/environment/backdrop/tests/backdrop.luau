local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local render = require '@testing/render'
local backdrop = require '../'
local fixture = require './support/fixture'

type Environment = fixture.Environment

local test = testing.suite()

local function visible(env: Environment, dt: number?): ()
  env.native.events.mainSessionVisible = false
  env.session:update(dt or 0.8)
  env.session:draw()
end

test('hidden primary and disabled states fade to zero without drawing or clearing', function()
  local factory = backdrop.create()
  local env = fixture.boot(factory)
  env.session:draw()
  expect.equal(#env.drawn, 0, 'no drawing before the first update')
  env.native.events.mainSessionVisible = true
  env.session:update(10)
  env.session:draw()
  expect.equal(#env.drawn, 0, 'primary visible stays fully hidden')
  expect.equal(#env.recorder.meshAcquisitions, 0, 'hidden acquires nothing')
  visible(env, 0.4)
  expect.near(env.uniforms.backdropSky[1], 0.5, 1e-8, 'first false sample fades in')
  factory.controls.setEnabled(false)
  env.session:update(0.4)
  local count = #env.drawn
  env.session:draw()
  expect.equal(#env.drawn, count, 'disabled fade ends with no draw')
  env.session:close()
end)

test('backdrop_restores_pass_on_failure', function()
  local env = fixture.boot(backdrop.create())
  env.pass:setShader 'unlit'
  env.pass:setMaterial { name = 'prior material' }
  env.pass:setBlendMode('add', 'alphamultiply')
  env.pass:setColor(0.1, 0.2, 0.3, 0.4)
  env.pass:setCullMode 'back'
  env.pass:setDepthTest 'lequal'
  env.pass:setDepthWrite(true)
  env.pass:translate(2, 3, 4)
  env.pass:rotate(0.7, 0, 1, 0)
  local checkpoint = env.recorder:checkpoint()
  local originalDraw = env.pass.draw
  local draws = 0
  function env.pass.draw(self: render.Pass, ...: any): ()
    draws += 1
    if draws == 2 then
      error('injected curtain draw failure', 0)
    end
    originalDraw(self, ...)
  end
  visible(env)
  local reports = env.native.events.reported
  expect.equal(#reports, 1, 'frame boundary reports the draw failure')
  expect.truthy(string.find(reports[1].message, 'injected curtain draw failure', 1, true), 'failure propagates')
  env.recorder:assertRestored(checkpoint)
  env.session:close()
end)

test('resource compilation failure restores the pass and releases partial acquisitions', function()
  local env = fixture.boot(backdrop.create())
  lovr.graphics.newShader = function()
    error('injected shader compile failure', 0)
  end
  visible(env)
  expect.equal(#env.native.events.reported, 1, 'compile failure reaches frame boundary')
  expect.equal(#env.recorder.meshAcquisitions, 3, 'meshes created before compilation')
  env.recorder:assertMeshesReleased()
  env.recorder:assertRestored()
  env.session:close()
end)

test('orientation stays world stable and the background draws before foreground', function()
  local env = fixture.boot(backdrop.create())
  env.native.events.headPose:identity():translate(vector.pack(2, 1, -3)):rotate(1.3, 0, 1, 0)
  local foreground = false
  env.session:use(plugin.consumer({
    name = 'testing/foreground',
    requires = { frame.capability },
    init = function(context: plugin.Context)
      local service = context:require(frame.capability)
      service:onDraw(context, {
        phase = 'scene',
        run = function()
          foreground = #env.drawn == 5
        end,
      })
    end,
  }).definition)
  visible(env)
  expect.equal(foreground, true, 'background is the first scene draw')
  local transform = env.drawn[1].transform
  local x, y, z = transform:getPosition()
  expect.near(x, 2, 1e-6, 'head translation x')
  expect.near(y, 1, 1e-6, 'head translation y')
  expect.near(z, -3, 1e-6, 'head translation z')
  local angle = transform:getOrientation()
  expect.near(angle, 0, 1e-6, 'head rotation is not copied')
  local calls = env.native.events.draw
  local background
  for _, call in calls do
    if call[1] == 'draw' then
      background = call
      break
    end
  end
  expect.equal(background.state.setDepthTest.n, 0, 'no depth testing')
  expect.equal(background.state.setDepthWrite[1], false, 'no depth writes')
  expect.equal(background.state.setBlendMode[2], 'premultiplied', 'premultiplied alpha')
  env.recorder:assertRestored()
  env.session:close()
end)

test('retained controls survive reactivation but independent definitions reset them', function()
  local factory = backdrop.create()
  local env = fixture.boot(factory)
  local process = env.native.newProcess(910)
  factory.choice:pin(process)
  factory.controls.setEnabled(false)
  local instance = env.session.instances['desktop/backdrop']
  instance:disable()
  instance:enable()
  env.session.runtime:drain()
  visible(env)
  expect.equal(#env.drawn, 0, 'retained disabled state survives reactivation')
  expect.equal(factory.controls.source().process, process, 'retained process identity survives reactivation')
  expect.equal(backdrop.create().controls.enabled(), true, 'new factory resets runtime enabled state')
  expect.equal(backdrop.create().controls.source().kind, 'system', 'new factory resets runtime source')
  env.session:close()
end)

test('only changes to configured enabled replace a retained runtime override', function()
  local factory = backdrop.create()
  factory.controls.setEnabled(false)
  local env = fixture.boot(factory)
  visible(env)
  expect.equal(#env.drawn, 0, 'override before activation survives')
  local instance = env.session.instances['desktop/backdrop']
  instance:requestReload { motion = 0.5 }
  env.session.runtime:drain()
  visible(env)
  expect.equal(#env.drawn, 0, 'unrelated configuration preserves runtime enabled')
  instance:requestReload { enabled = false }
  env.session.runtime:drain()
  factory.controls.setEnabled(true)
  visible(env)
  local count = #env.drawn
  expect.truthy(count > 0, 'runtime override enables a configured-disabled backdrop')
  instance:requestReload { enabled = true }
  env.session.runtime:drain()
  instance:requestReload { enabled = false }
  env.session.runtime:drain()
  visible(env)
  expect.equal(#env.drawn, count, 'changed enabled setting replaces runtime override')
  env.session:close()
end)

test('retained selection changes override only their corresponding configured fields', function()
  local factory = backdrop.create()
  local env = fixture.boot(factory)
  local process = env.native.newProcess(920)
  factory.choice:pin(process)
  factory.choice:setReactive(false)
  factory.choice:setResponse(0.25)
  factory.choice:setMotion(0)
  local instance = env.session.instances['desktop/backdrop']
  instance:requestReload { brightness = 0.4 }
  env.session.runtime:drain()
  expect.equal(factory.choice.pinned, process, 'unrelated reload retains process handle')
  expect.equal(factory.choice.mode, 'application', 'unrelated reload retains source mode')
  expect.equal(factory.choice.reactive, false, 'unrelated reload retains reactive choice')
  expect.equal(factory.choice.response, 0.25, 'unrelated reload retains response')
  expect.equal(factory.choice.motion, 0, 'unrelated reload retains motion')
  visible(env, 0.1)
  expect.equal(env.uniforms.backdropSky[2], 0, 'retained motion reaches renderer')
  instance:requestReload { sourceMode = 'attention', response = 0.5, motion = 0.8 }
  env.session.runtime:drain()
  expect.equal(factory.choice.mode, 'attention', 'changed mode overrides retained mode')
  expect.equal(factory.choice.pinned, process, 'changing mode does not destroy pinned identity')
  expect.equal(factory.choice.response, 0.5, 'changed response overrides only response')
  expect.equal(factory.choice.motion, 0.8, 'changed motion overrides only motion')
  expect.equal(factory.choice.reactive, false, 'unchanged reactive remains runtime choice')
  env.session:close()
end)

return test
