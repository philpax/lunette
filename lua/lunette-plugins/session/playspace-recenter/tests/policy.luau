local testing = require '@testing'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'
local frame = require '@lunette-contracts/frame'
local laser = require '@lunette-contracts/laser'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local test = testing.suite()

local ID = 'desktop/playspace/recenter'

type State = { status: string, calls: number, result: boolean, failure: string? }
type Environment = {
  session: testing.Session,
  service: menu.Service,
  state: State,
  native: testing.Native,
}

local function boot(status: string): Environment
  local native = testing.native()
  local state: State = { status = status, calls = 0, result = true, failure = nil }
  lovr.headset.getRecenterStatus = function(): string
    return state.status
  end
  lovr.headset.recenter = function(): boolean
    state.calls += 1
    if state.failure then
      error(state.failure)
    end
    return state.result
  end
  local session = testing.boot({
    'frame',
    'menu',
    { id = 'desktop/recenter', definition = require('../').definition },
  }, { native = native })
  local service = session:observe(menu.capability).service
  return { session = session, service = service, state = state, native = native }
end

local function row(env: Environment): menu.Descriptor
  local actions = env.service:list()
  expect.equal(#actions, 1, 'recenter requires no workspace or panel services')
  expect.equal(actions[1].id, ID)
  expect.equal(actions[1].label, 'Recenter playspace')
  return actions[1]
end

test('every unavailable status stays listed with a reason and refreshes each frame', function(): ()
  local env = boot 'unsupported'
  local previous = nil
  for _, status in { 'unsupported', 'untracked', 'unavailable' } do
    env.state.status = status
    env.session:update()
    local action = row(env)
    expect.equal(action.enabled, false)
    expect.truthy(type(action.disabledReason) == 'string' and #action.disabledReason > 0)
    expect.falsy(action.disabledReason == previous, 'different conditions have different reasons')
    previous = action.disabledReason
    expect.equal(env.service:invoke(ID).kind, 'unavailable')
    expect.equal(env.state.calls, 0)
    env.state.status = 'available'
    env.session:update()
    expect.equal(row(env).enabled, true)
    expect.equal(row(env).disabledReason, nil, 'recovery clears the reason')
  end
  env.session:close()
end)

test('an available action queues one reset and rechecks status in the next input phase', function(): ()
  local env = boot 'available'
  expect.equal(row(env).enabled, true)
  expect.equal(env.service:invoke(ID).kind, 'invoked')
  expect.equal(env.state.calls, 0, 'the invoking pointer finishes in the old coordinate frame')
  expect.equal(row(env).enabled, false, 'a pending reset disables the action')
  expect.equal(env.service:invoke(ID).kind, 'unavailable', 'pending requests are debounced')
  env.state.status = 'untracked'
  env.session:update()
  expect.equal(env.state.calls, 0, 'tracking lost after queueing prevents recenter')
  expect.equal(row(env).enabled, false)
  env.state.status = 'available'
  env.session:update()
  env.state.result = false
  env.service:invoke(ID)
  expect.equal(env.state.calls, 0)
  env.session:update()
  expect.equal(env.state.calls, 1, 'a runtime refusal is not retried')
  env.session:update()
  expect.equal(env.state.calls, 1)
  expect.equal(row(env).enabled, true, 'availability comes from status, not a cached result')
  env.session:close()
end)

test('operation errors reach the protected frame boundary without retrying', function(): ()
  local env = boot 'available'
  env.state.failure = 'fixture recenter operation failed'
  expect.equal(env.service:invoke(ID).kind, 'invoked')
  expect.equal(env.state.calls, 0)
  env.session:update()
  expect.equal(env.state.calls, 1)
  local reports = env.native.events.reported
  testing.takeReports()
  expect.equal(#reports, 1)
  expect.truthy(reports[1].message:find('fixture recenter operation failed', 1, true))
  env.session:update()
  expect.equal(env.state.calls, 1, 'a failed request is consumed')
  expect.equal(row(env).enabled, true)
  env.session:close()
end)

test('recenter leaves world poses unchanged in active and inactive workspaces', function(): ()
  local session = testing.boot {
    'frame',
    'menu',
    'theme',
    'panels',
    'tags',
    'rules',
    'placement',
    {
      id = 'desktop/workspaces',
      definition = require('@lunette-plugins/workspace/controller').definition,
      config = { names = { 'main', 'side' } },
    },
    { id = 'desktop/recenter', definition = require('../').definition },
  }
  local placement = session:observe(require('@lunette-contracts/placement').capability)
  local actions = session:observe(menu.capability).service
  local function place(id: number): panels.WindowPanel
    return placement.service:place(placement.context, { window = session.native.newWindow(id) }).panel
  end
  local first = place(101)
  actions:invoke 'desktop/workspace/side'
  local second = place(102)
  first:setPose(lovr.math.newMat4():translate(2, 1, -4):rotate(0.4, 0, 1, 0))
  second:setPose(lovr.math.newMat4():translate(-3, 2, -5):rotate(-0.6, 0, 1, 0))
  local before = { { first.pose:unpack(true) }, { second.pose:unpack(true) } }
  expect.truthy(first.hidden, 'the first workspace is inactive')
  expect.falsy(second.hidden, 'the second workspace is active')
  lovr.headset.getRecenterStatus = function(): string
    return 'available'
  end
  local calls = 0
  lovr.headset.recenter = function(): boolean
    calls += 1
    session.native.events.headPose:set(lovr.math.newMat4():translate(0, 1.7, 0))
    return true
  end
  session:update()
  actions:invoke(ID)
  expect.equal(calls, 0)
  session:update()
  expect.equal(calls, 1)
  for index, panel in { first, second } do
    local after = { panel.pose:unpack(true) }
    for component, value in before[index] do
      expect.near(after[component], value, 1e-6, 'recenter does not compensate a stored world pose')
    end
  end
  expect.truthy(first.hidden, 'recenter does not select the inactive workspace')
  expect.falsy(second.hidden)
  session.instances['desktop/recenter']:disable()
  for _, action in actions:list() do
    expect.falsy(action.id == ID, 'deactivation removes the recenter action')
  end
  session:close()
end)

test('a queued reset is discarded when its activation ends', function(): ()
  local env = boot 'available'
  env.service:invoke(ID)
  env.session.instances['desktop/recenter']:disable()
  env.session.instances['desktop/recenter']:enable()
  env.session:update()
  expect.equal(env.state.calls, 0, 'reactivation does not inherit a pending request')
  expect.equal(row(env).enabled, true)
  env.session:close()
end)

test('recenter cancels an active grab before pointing and reacquires without cached aim or held grip', function(): ()
  local native = testing.native()
  local controls = vrUi.hands(native)
  controls:pose('left', lovr.math.newMat4():translate(-2, 0, 0))
  controls:pose('right', lovr.math.newMat4())
  lovr.headset.getRecenterStatus = function(): string
    return 'available'
  end
  local calls = 0
  lovr.headset.recenter = function(): boolean
    calls += 1
    controls:tracked('left', false)
    controls:tracked('right', false)
    return true
  end
  local session = testing.boot({
    'frame',
    'menu',
    'theme',
    'panels',
    'drops',
    'focus',
    'interaction',
    'laser',
    { id = 'desktop/recenter', definition = require('../').definition },
  }, { native = native })
  local panelService = session:observe(panels.capability)
  local panel = panelService.service:fromWindow(panelService.context, native.newWindow(201), {
    pose = lovr.math.newMat4():translate(0, 0, -2),
    height = 1,
  })
  local actions = session:observe(menu.capability).service
  local beams = session:observe(laser.capability)
  local attached = beams.service:attach(beams.context)
  local pointer = attached[2].pointer
  local invoked = false
  local menuTarget = {
    dead = false,
    grabbable = false,
    raycast = function(_: laser.Surface, origin: vector): (number?, number?, number?)
      if origin.x < -1 then
        return 0, 0, 1
      end
      return nil
    end,
    onPointer = function(_: laser.Surface, event: laser.PointerEvent): ()
      if event.kind == 'press' then
        invoked = true
        expect.equal(actions:invoke(ID).kind, 'invoked')
        expect.equal(calls, 0, 'the left pointer does not reset coordinates under the right pointer')
      end
    end,
  }
  local origins: { vector } = {}
  local probe = {
    dead = false,
    raycast = function(_: laser.Surface, origin: vector): nil
      origins[#origins + 1] = origin
      return nil
    end,
  }
  local frames = session:observe(frame.capability)
  frames.service:onUpdate(frames.context, {
    phase = 'pointing',
    run = function(_dt: number): ()
      beams.service:update { menuTarget, panel, probe }
    end,
  })
  session:update()
  controls:button('right', 'grip', true)
  session:update()
  expect.equal(pointer.grabbed, panel, 'the right laser holds a real panel')
  controls:pose('right', lovr.math.newMat4():translate(0.1, 0, 0))
  session:update()
  controls:button('left', 'trigger', true)
  session:update()
  expect.truthy(invoked, 'the other hand queues recenter from a pointing callback')
  expect.equal(calls, 0)
  expect.equal(pointer.grabbed, panel, 'the invoking frame finishes normally')
  local before = { panel.pose:unpack(true) }
  session:update()
  expect.equal(calls, 1)
  expect.equal(pointer.grabbed, nil, 'the input-phase reset withdraws the old grab before pointing')
  expect.equal(pointer.hovered, nil)
  for index, value in before do
    expect.near(({ panel.pose:unpack(true) })[index], value, 1e-6, 'withdrawal does not overwrite the world pose')
  end
  controls:pose('left', lovr.math.newMat4():translate(-1.99, 0, 0))
  controls:tracked('left', true)
  controls:pose('right', lovr.math.newMat4():translate(0.2, 0, 0))
  controls:tracked('right', true)
  table.clear(origins)
  session:update()
  expect.equal(#origins, 2, 'both freshly tracked hands contribute rays')
  expect.near(origins[1].x, -1.99, 1e-6, 'a held trigger does not restore the cached trigger-lock origin')
  expect.near(origins[2].x, 0.2, 1e-6, 'fresh tracking starts aim at the new origin, not the cached filter')
  expect.equal(pointer.grabbed, nil, 'held grip stays quarantined after tracking returns')
  controls:pose('right', lovr.math.newMat4():translate(0.3, 0, 0))
  session:update()
  for index, value in before do
    expect.near(({ panel.pose:unpack(true) })[index], value, 1e-6, 'a held grip cannot move the panel after recenter')
  end
  controls:button('right', 'grip', false)
  session:update()
  controls:button('right', 'grip', true)
  session:update()
  expect.equal(pointer.grabbed, panel, 'an observed release permits a fresh grab')
  session:close()
end)

return test
