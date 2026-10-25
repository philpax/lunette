local testing = require '@testing'
local expect = testing.expect
local decision = require '../private/decision'
local test = testing.suite()

local THRESHOLDS: decision.Thresholds = { errorFrames = 3, quietFrames = 2, healthySeconds = 5 }

type Frame = { missing: { string }?, hostErrors: number?, now: number?, changed: boolean? }

-- Steps through frames from the initial state and answers every decision.
local function run(frames: { Frame }): { decision.Decision }
  local state = decision.initial()
  local decisions: { decision.Decision } = {}
  for index, frame in frames do
    local result = decision.step(state, {
      missing = frame.missing or {},
      hostErrors = frame.hostErrors or 0,
      now = frame.now or index,
      changed = frame.changed == true,
    }, THRESHOLDS)
    decisions[#decisions + 1] = result
    state = result.state
  end
  return decisions
end

test('a toolkit capability without an active provider shows the panel at once', function()
  local decisions = run { {}, { missing = { 'lunette/ui-host' } }, {} }
  expect.falsy(decisions[1].visible, 'hidden while the toolkit runs')
  expect.truthy(decisions[2].visible, 'shown while the host is missing')
  expect.equal(decisions[2].reason, 'missing', 'the reason')
  expect.falsy(decisions[3].visible, 'hidden once the host is back')
end)

test('host errors show the panel only after errorFrames consecutive frames', function()
  local decisions = run {
    { hostErrors = 1 },
    { hostErrors = 2 },
    {},
    { hostErrors = 1 },
    { hostErrors = 1 },
    { hostErrors = 1 },
  }
  for index = 1, 5 do
    expect.falsy(decisions[index].visible, `frame {index} is below the threshold`)
  end
  expect.truthy(decisions[6].visible, 'the third consecutive frame crosses it')
  expect.equal(decisions[6].reason, 'failing', 'the reason')
end)

test('a panel shown for errors stays until quietFrames frames pass without one', function()
  local decisions = run {
    { hostErrors = 1 },
    { hostErrors = 1 },
    { hostErrors = 1 },
    {},
    { hostErrors = 1 },
    {},
    {},
    {},
  }
  expect.truthy(decisions[4].visible, 'one quiet frame is not enough')
  expect.truthy(decisions[5].visible, 'an error resets the quiet count')
  expect.truthy(decisions[6].visible, 'the first quiet frame after it')
  expect.falsy(decisions[7].visible, 'quietFrames quiet frames hide it')
end)

test('a composition is marked good once after staying healthy for healthySeconds', function()
  local decisions = run {
    { now = 0 },
    { now = 4.9 },
    { now = 5 },
    { now = 9 },
  }
  expect.falsy(decisions[2].markGood, 'not yet healthy for long enough')
  expect.truthy(decisions[3].markGood, 'healthy for the whole duration')
  expect.falsy(decisions[4].markGood, 'a stretch is marked once')
end)

test('a change, an error, or a missing provider restarts the healthy stretch', function()
  local decisions = run {
    { now = 0 },
    { now = 4, changed = true },
    { now = 8 },
    { now = 9 },
    { now = 10, hostErrors = 1 },
    { now = 11 },
    { now = 15 },
    { now = 16 },
    { now = 17, missing = { 'lunette/ui-components' } },
    { now = 18 },
    { now = 23 },
  }
  expect.falsy(decisions[3].markGood, 'the change at 4 restarted the stretch')
  expect.truthy(decisions[4].markGood, 'five seconds after the change')
  expect.falsy(decisions[7].markGood, 'the error at 10 restarted it')
  expect.truthy(decisions[8].markGood, 'five seconds after the error')
  expect.falsy(decisions[9].markGood, 'never while a provider is missing')
  expect.falsy(decisions[10].markGood, 'the stretch restarts when it returns')
  expect.truthy(decisions[11].markGood, 'five seconds after it returned')
end)

test('a composition is never marked good while errors persist', function()
  local frames: { Frame } = {}
  for index = 1, 20 do
    frames[index] = { now = index, hostErrors = 1 }
  end
  for _, result in run(frames) do
    expect.falsy(result.markGood, 'no mark while the host fails')
  end
end)

test('fromHost matches a report by its context prefix', function()
  expect.truthy(decision.fromHost("ui: panel 'x' draw: boom", { 'ui:' }), 'the host context')
  expect.falsy(decision.fromHost('frame.onUpdate: boom', { 'ui:' }), 'another context')
  expect.falsy(decision.fromHost('anything', { '' }), 'an empty prefix matches nothing')
end)

return test
