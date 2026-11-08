local testing = require '@testing'
local plugin = require '@lunette-plugin'
local render = require '@testing/render'
local config = require '../../config'
local draw = require '../../private/rendering/draw'
local model = require '../../private/rendering/model'
local selection = require '../../private/selection/selection'
local expect = testing.expect
local fixture = {}

export type Environment = {
  session: testing.Session,
  recorder: render.Recorder,
  pass: render.Pass,
  state: model.State,
  renderer: draw.Renderer,
  diagnostic: selection.Diagnostic,
}

function fixture.boot(large: boolean?): Environment
  local session = testing.boot {}
  local settings = config.schema.parse {}
  local recorder = session.native.events.render
  recorder.width, recorder.height, recorder.viewCount, recorder.samples = if large then 960 else 640, 640, 2, 4
  local env =
    { session = session, recorder = recorder, pass = recorder.pass, state = model.new(settings), diagnostic = 'none' }
  session:use(plugin.consumer({
    name = 'testing/backdrop-renderer',
    init = function(context: plugin.Context): ()
      env.renderer = draw.new(context, settings, function(): selection.Diagnostic
        return env.diagnostic
      end)
    end,
  }).definition)
  return env
end

function fixture.frame(env: Environment, count: number?): model.Frame
  local value = table.clone(env.state:update(0, false))
  value.visibility, value.brightness, value.responseStrength, value.time = 1, 0.8, 0.6, 23
  value.waves = {}
  local bands = { 'treble', 'bass', 'mid' }
  for index = 1, count or 9 do
    local band = bands[(index - 1) % #bands + 1]
    value.waves[index] = {
      age = 0.08,
      strength = 0.7,
      position = index / 32,
      frequency = index / 32,
      band = band,
      lifetime = model.waveLifetimes[band],
    }
  end
  return value
end

function fixture.calls(recorder: render.Recorder, method: string): { render.Call }
  local found = {}
  for _, call in recorder.calls do
    if call[1] == method then
      table.insert(found, call)
    end
  end
  return found
end

function fixture.seedState(env: Environment): render.Checkpoint
  env.pass:setShader 'unlit'
  env.pass:setColor(0.2, 0.3, 0.4, 0.5)
  env.pass:setDepthTest('greater', 0.7)
  env.pass:setDepthWrite(true)
  env.pass:setBlendMode('add', 'alphamultiply')
  env.pass:translate(7, -3, 2)
  return env.recorder:checkpoint()
end

function fixture.preparation(result: { render.Pass }?): render.Pass
  expect.truthy(result, 'the scene returns prerequisite passes')
  expect.equal(#result, 1, 'one pass prepares the curtains')
  return result[1]
end

function fixture.close(env: Environment): ()
  env.session:close()
  env.recorder:assertResourcesReleased()
end

return fixture
