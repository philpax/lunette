local testing = require '@testing'
local fixture = require './support/source-controls'
local expect = testing.expect
local test = testing.suite()

local VIEWS = 'body/response/content/views/'

local function count(env: fixture.Environment, method: string): number
  local found = 0
  for _, call in env.native.events.draw do
    if call[1] == method then
      found += 1
    end
  end
  return found
end

test('the open control panel draws the sky model and the skyline as volumes every frame', function()
  local env = fixture.boot()
  fixture.open(env)
  expect.truthy(fixture.visible(env), 'the panel is open')
  local modelNode = fixture.node(env, VIEWS .. 'model')
  expect.truthy(fixture.node(env, VIEWS .. 'skyline'), 'the skyline is on the panel')
  table.clear(env.native.events.draw)
  env.running:draw()
  expect.equal(#env.view.models, 1, 'the model draws the backdrop in miniature')
  local drawn = env.view.models[1]
  expect.truthy(drawn.radius > 0 and drawn.radius <= modelNode.bounds.width / 2, 'the model fits its node')
  expect.equal(drawn.opacity, 1)
  expect.truthy(count(env, 'box') >= 16, 'the skyline draws a pair of columns for every band')
  expect.truthy(count(env, 'capsule') >= 12, 'the model marks each sector edge')
  env.running:draw()
  expect.equal(#env.view.models, 2, 'the model draws again without the panel changing')
  expect.equal(fixture.node(env, 'body/response/content/onsets').props.text, 'Silent.', 'the caption reports silence')
  fixture.click(env, 'body/reactive')
  env.running:step(0)
  expect.equal(fixture.node(env, 'body/response/content/onsets').props.text, 'Audio reactivity is off.')
  env.running:close()
end)

test('the closed control panel draws neither view', function()
  local env = fixture.boot()
  env.running:step(0)
  table.clear(env.native.events.draw)
  env.running:draw()
  expect.equal(#env.view.models, 0)
  env.running:close()
end)

return test
