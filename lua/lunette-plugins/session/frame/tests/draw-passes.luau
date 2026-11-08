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

local function registerResult(
  env: environment.Environment,
  name: string,
  result: contract.DrawPasses
): adapter.Instance<{}>
  return register(env, name, function(): contract.DrawPasses
    return result
  end)
end

local function draw(env: environment.Environment): (boolean, contract.DrawPasses?)
  return lovr.draw(env.native.events.pass)
end

test('preparatory passes follow phase, order, registration, and list order', function()
  local env = environment.start()
  local a, b, c, d, e = pass(), pass(), pass(), pass(), pass()
  local returned = { a, b }
  environment.consumer(env, 'draw-order', function(context: plugin.Context, service: contract.Service)
    for _, handler in ipairs {
      { phase = 'overlay', result = { e } },
      { phase = 'scene', order = 1, result = { d } },
      { phase = 'scene', result = returned },
      { phase = 'scene', result = { c } },
    } do
      service:onDraw(context, {
        phase = handler.phase,
        order = handler.order,
        run = function(): contract.DrawPasses
          return handler.result
        end,
      })
    end
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

test('a failed callback contributes nothing and does not stop later callbacks', function()
  local env = environment.start()
  local later = pass()
  register(env, 'draw-failure', function()
    error 'draw callback failure'
  end)
  registerResult(env, 'draw-after-failure', { later })
  local _, extras = draw(env)
  expect.equal(#extras, 1, 'only the later callback contributes')
  expect.equal(extras[1], later, 'the later callback still runs')
  expect.equal(#env.native.events.reported, 1, 'the failure is reported once')
  expect.truthy(string.find(env.native.events.reported[1].message, 'draw callback failure', 1, true), 'the error')
  env.session:close()
end)

test('malformed results are reported and discarded atomically', function()
  local duplicate = pass()
  local cases = {
    { name = 'boolean', result = false, message = 'a plain dense array of Pass objects or nil' },
    { name = 'scalar', result = pass(), message = 'a plain dense array of Pass objects or nil' },
    { name = 'metatable', result = setmetatable({}, {}), message = 'a plain dense array' },
    { name = 'hole', result = { [1] = pass(), [3] = pass() }, message = 'dense' },
    { name = 'field', result = { pass(), extra = pass() }, message = 'dense' },
    { name = 'zero', result = { [0] = pass() }, message = 'dense' },
    { name = 'fraction', result = { [1.5] = pass() }, message = 'dense' },
    { name = 'large-index', result = { [1e12] = pass() }, message = 'dense' },
    { name = 'invalid-pass', result = { pass(), {} }, message = 'result[2] is a Pass object' },
    { name = 'wrong-object', result = { pass(), lovr.math.newMat4() }, message = 'result[2] is a Pass object' },
    { name = 'duplicate', result = { duplicate, duplicate }, message = 'already appears' },
    {
      name = 'main',
      run = function(main: Pass): unknown
        return { pass(), main }
      end,
      message = 'is the main draw Pass',
    },
  }
  for _, case in ipairs(cases) do
    local env = environment.start()
    local before, after = pass(), pass()
    registerResult(env, 'draw-before', { before })
    register(env, 'draw-malformed', case.run or function(): unknown
      return case.result
    end)
    registerResult(env, 'draw-after', { after })
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
  registerResult(env, 'draw-first', { first })
  registerResult(env, 'draw-duplicate', { nextPass, first })
  registerResult(env, 'draw-next', { nextPass })
  local _, extras = draw(env)
  expect.equal(#extras, 2, 'the invalid result contributes nothing')
  expect.equal(extras[1], first, 'the first callback contributes')
  expect.equal(extras[2], nextPass, 'a rejected result does not reserve passes')
  expect.equal(#env.native.events.reported, 1, 'the duplicate is reported')
  env.session:close()
end)

return test
