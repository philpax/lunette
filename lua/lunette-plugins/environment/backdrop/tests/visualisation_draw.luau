local testing = require '@testing'
local fixture = require './support/visuals'
local expect = testing.expect
local test = testing.suite()

local function same(actual: unknown, expected: unknown): ()
  expect.equal(type(actual), type(expected))
  if type(expected) == 'table' then
    local actualTable = actual :: { [any]: unknown }
    local expectedTable = expected :: { [any]: unknown }
    local count, wanted = 0, 0
    for key, value in expectedTable do
      wanted += 1
      same(actualTable[key], value)
    end
    for _ in actualTable do
      count += 1
    end
    expect.equal(count, wanted)
  else
    expect.equal(actual, expected)
  end
end

test('rerun visuals and retained callbacks draw current raw levels in back-to-front order', function()
  testing.native()
  local env = fixture.new()
  local first, second = env.node(), env.node()
  local firstDraw = env.visual('skyline', first)
  local secondDraw = env.visual('skyline', second)
  firstDraw(env.pass :: any, env.volume)
  same(env.events, env.skylineExpected())
  for index = 1, 8 do
    env.sources.history[index + 1] = { spectrum = table.create(8, index / 10), stereo = table.create(8, 0.1) }
  end
  env.sources.observed = { raw = { 0, 0.8 }, frame = { waves = {} } :: any }
  env.sources.palette.bass[1] = 1
  env.volume.width, env.volume.height, env.volume.opacity, env.volume.scrim = 0.5, 0.1, 0.3, 0.1
  secondDraw(env.pass :: any, env.volume)
  table.clear(env.events)
  firstDraw(env.pass :: any, env.volume)
  same(env.events, env.skylineExpected())
  table.clear(env.events)
  env.visual('skyline', first)(env.pass :: any, env.volume)
  same(env.events, env.skylineExpected())
  table.clear(env.sources.history)
  table.clear(env.sources.observed.raw)
  table.clear(env.events)
  firstDraw(env.pass :: any, env.volume)
  expect.equal(#env.events, 0, 'removed rows and caps do not remain visible')
  env.close()
end)

test('model callbacks read live onsets, orientation, theme, opacity, and replacement observations', function()
  testing.native()
  local env = fixture.new()
  local node = env.node()
  local draw = env.visual('model', node)
  draw(env.pass :: any, env.volume)
  local firstAccent = env.events[17].color :: { number }
  node.theme = { colors = { accent = { 0.8, 0.2, 0.1, 0.5 } }, radii = { control = 0.01 } }
  env.sources.observed = {
    raw = {},
    facing = 0.1,
    anchor = 0.75,
    frame = {
      waves = {
        { band = 'bass', position = 0.25, lifetime = 1, age = 0.5, strength = 0.8, frequency = 0.5 },
      },
    } :: any,
  }
  env.volume.pose:rotate(0.7, 0, 1, 0)
  table.clear(env.events)
  draw(env.pass :: any, env.volume)
  expect.near(env.events[3][2], -0.7, 1e-6, 'the model undoes the current volume orientation')
  local nextAccent = env.events[17].color :: { number }
  expect.truthy(nextAccent[1] ~= firstAccent[1], 'a retained volume callback reads the current theme')
  expect.near(nextAccent[1], 0.8 * (1 - env.volume.scrim), 1e-9)
  expect.near(nextAccent[4], 0.5 * env.volume.opacity, 1e-9)
  expect.equal(env.events[#env.events].method, 'sphere', 'the live onset draws after the head')
  expect.equal(env.miniature.frame, env.sources.observed.frame)
  expect.equal(env.miniature.facing, 0.1)
  expect.equal(env.miniature.opacity, env.volume.opacity * (1 - env.volume.scrim))
  env.close()
  local fresh = fixture.new()
  local nextNode = fresh.node()
  fresh.visual('skyline', nextNode)(fresh.pass :: any, fresh.volume)
  same(fresh.events, fresh.skylineExpected())
  fresh.close()
end)

return test
