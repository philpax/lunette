local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local contract = require '@lunette-contracts/frame'
local environment = require './support/environment'

local test = testing.suite()

local function pass(): Pass
  local value = newproxy(true)
  getmetatable(value).__index = {
    type = function(): string
      return 'Pass'
    end,
  }
  return value :: any
end

local function register(env: environment.Environment, name: string, run: contract.DrawRun): adapter.Instance<{}>
  return environment.consumer(env, name, function(context: plugin.Context, service: contract.Service)
    service:onDraw(context, { phase = 'scene', run = run })
  end)
end

local function draw(env: environment.Environment): (boolean, contract.DrawPasses?)
  return lovr.draw(env.native.events.pass)
end

local function expectNone(env: environment.Environment, label: string)
  local skip, extras = draw(env)
  expect.equal(skip, false, label .. ' keeps the main pass')
  expect.equal(extras, nil, label .. ' has no preparatory passes')
end

test('missing handlers, void handlers, nil, and empty lists preserve the draw result', function()
  local env = environment.start()
  expectNone(env, 'no handler')
  register(env, 'draw-void', function() end)
  register(env, 'draw-nil', function(): nil
    return nil
  end)
  register(env, 'draw-empty', function(): contract.DrawPasses
    return {}
  end)
  expectNone(env, 'empty results')
  expect.equal(#env.native.events.reported, 0, 'empty results are valid')
  env.session:close()
  expectNone(env, 'no provider')
end)

test('preparatory passes follow phase, order, registration, and list order', function()
  local env = environment.start()
  local a, b, c, d, e = pass(), pass(), pass(), pass(), pass()
  local returned = { a, b }
  environment.consumer(env, 'draw-order', function(context: plugin.Context, service: contract.Service)
    service:onDraw(context, {
      phase = 'overlay',
      run = function(): contract.DrawPasses
        return { e }
      end,
    })
    service:onDraw(context, {
      phase = 'scene',
      order = 1,
      run = function(): contract.DrawPasses
        return { d }
      end,
    })
    service:onDraw(context, {
      phase = 'scene',
      run = function(): contract.DrawPasses
        return returned
      end,
    })
    service:onDraw(context, {
      phase = 'scene',
      run = function(): contract.DrawPasses
        return { c }
      end,
    })
  end)
  local skip, extras = draw(env)
  expect.equal(skip, false, 'the first result stays false')
  expect.equal(#extras, 5, 'all passes are collected')
  for index, expected in ipairs { a, b, c, d, e } do
    expect.equal(extras[index], expected, 'pass ' .. index)
  end
  table.clear(returned)
  expect.equal(#extras, 5, 'the returned list is copied')
  env.session:close()
end)

test('frozen results are copied and the same Pass can be returned in distinct draw invocations', function()
  local env = environment.start()
  local preparation = pass()
  local result = table.freeze { preparation }
  register(env, 'draw-frozen', function(): contract.DrawPasses
    return result
  end)
  local _, first = draw(env)
  local _, second = draw(env)
  expect.equal(first[1], preparation, 'the first invocation collects the frozen result')
  expect.equal(second[1], preparation, 'duplicate detection ends with the invocation')
  expect.falsy(first == result or second == result or first == second, 'each invocation owns a new list')
  expect.equal(#env.native.events.reported, 0, 'neither invocation reports an error')
  env.session:close()
end)

test('a failed callback contributes nothing and does not stop later callbacks', function()
  local env = environment.start()
  local later = pass()
  register(env, 'draw-failure', function()
    error 'draw callback failure'
  end)
  register(env, 'draw-after-failure', function(): contract.DrawPasses
    return { later }
  end)
  local _, extras = draw(env)
  expect.equal(#extras, 1, 'only the later callback contributes')
  expect.equal(extras[1], later, 'the later callback still runs')
  expect.equal(#env.native.events.reported, 1, 'the failure is reported once')
  expect.truthy(string.find(env.native.events.reported[1].message, 'draw callback failure', 1, true), 'the error')
  env.session:close()
end)

test('malformed results are reported and discarded atomically', function()
  local cases = {
    {
      name = 'boolean',
      result = function(): unknown
        return false
      end,
      message = 'a plain dense array of Pass objects or nil',
    },
    {
      name = 'scalar',
      result = function(): unknown
        return pass()
      end,
      message = 'a plain dense array of Pass objects or nil',
    },
    {
      name = 'metatable',
      result = function(): unknown
        return setmetatable({}, {})
      end,
      message = 'a plain dense array',
    },
    {
      name = 'hole',
      result = function(): unknown
        return { [1] = pass(), [3] = pass() }
      end,
      message = 'dense',
    },
    {
      name = 'field',
      result = function(): unknown
        return { pass(), extra = pass() }
      end,
      message = 'dense',
    },
    {
      name = 'zero',
      result = function(): unknown
        return { [0] = pass() }
      end,
      message = 'dense',
    },
    {
      name = 'fraction',
      result = function(): unknown
        return { [1.5] = pass() }
      end,
      message = 'dense',
    },
    {
      name = 'large-index',
      result = function(): unknown
        return { [1e12] = pass() }
      end,
      message = 'dense',
    },
    {
      name = 'invalid-pass',
      result = function(): unknown
        return { pass(), {} }
      end,
      message = 'result[2] is a Pass object',
    },
    {
      name = 'wrong-object',
      result = function(): unknown
        return { pass(), lovr.math.newMat4() }
      end,
      message = 'result[2] is a Pass object',
    },
    {
      name = 'main',
      result = function(main: Pass): unknown
        return { pass(), main }
      end,
      message = 'is the main draw Pass',
    },
    {
      name = 'duplicate',
      result = function(): unknown
        local p = pass()
        return { p, p }
      end,
      message = 'already appears',
    },
  }
  for _, case in ipairs(cases) do
    local env = environment.start()
    local before, after = pass(), pass()
    register(env, 'draw-before', function(): contract.DrawPasses
      return { before }
    end)
    register(env, 'draw-malformed', case.result)
    register(env, 'draw-after', function(): contract.DrawPasses
      return { after }
    end)
    local skip, extras = draw(env)
    expect.equal(skip, false, case.name .. ' keeps the main pass')
    expect.equal(#extras, 2, case.name .. ' contributes no partial result')
    expect.equal(extras[1], before, case.name .. ' preserves earlier passes')
    expect.equal(extras[2], after, case.name .. ' preserves later passes')
    expect.equal(#env.native.events.reported, 1, case.name .. ' is reported once')
    local message = env.native.events.reported[1].message
    expect.truthy(string.find(message, case.message, 1, true), case.name .. ': ' .. message)
    expect.truthy(string.find(env.native.events.reported[1].logged, 'lovr.draw', 1, true), 'the callback context')
    env.session:close()
  end
end)

test('duplicates across callbacks reject the entire later result without reserving its other passes', function()
  local env = environment.start()
  local first, nextPass = pass(), pass()
  register(env, 'draw-first', function(): contract.DrawPasses
    return { first }
  end)
  register(env, 'draw-duplicate', function(): contract.DrawPasses
    return { nextPass, first }
  end)
  register(env, 'draw-next', function(): contract.DrawPasses
    return { nextPass }
  end)
  local _, extras = draw(env)
  expect.equal(#extras, 2, 'the invalid result contributes nothing')
  expect.equal(extras[1], first, 'the first callback contributes')
  expect.equal(extras[2], nextPass, 'a rejected result does not reserve passes')
  expect.equal(#env.native.events.reported, 1, 'the duplicate is reported')
  env.session:close()
end)

test('dense results have no arbitrary preparatory pass count limit', function()
  local env = environment.start()
  local expected = {}
  for _ = 1, 96 do
    expected[#expected + 1] = pass()
  end
  register(env, 'draw-many', function(): contract.DrawPasses
    return expected
  end)
  local _, extras = draw(env)
  expect.equal(#extras, #expected, 'all preparatory passes are collected')
  expect.equal(#env.native.events.reported, 0, 'the dense result is accepted')
  env.session:close()
end)

test('draw results do not persist between invocations or provider activations', function()
  local env = environment.start()
  local first = pass()
  local calls = 0
  register(env, 'draw-once', function(): contract.DrawPasses?
    calls += 1
    return if calls == 1 then { first } else nil
  end)
  local _, extras = draw(env)
  expect.equal(extras[1], first, 'the first invocation contributes')
  expectNone(env, 'the next invocation')
  local provider = env.session.instances.frame
  provider:disable()
  expectNone(env, 'a provider outage')
  provider:enable()
  local _, resumed = draw(env)
  expect.equal(resumed, nil, 'the recovered handler retains no previous result')
  expect.equal(#env.native.events.reported, 0, 'recovery reports no error')
  env.session:close()
end)

test('disposed owners and registrations are skipped during draw', function()
  local env = environment.start()
  local removed
  local returned = pass()
  register(env, 'draw-disposer', function(): nil
    removed:disable()
    return nil
  end)
  removed = register(env, 'draw-removed', function(): contract.DrawPasses
    return { returned }
  end)
  expectNone(env, 'an owner disposed before its callback')
  local active = register(env, 'draw-active', function(): contract.DrawPasses
    return { returned }
  end)
  local _, extras = draw(env)
  expect.equal(extras[1], returned, 'a live owner contributes')
  active:disable()
  expectNone(env, 'a disposed owner on the next invocation')
  env.session:close()
end)

return test
