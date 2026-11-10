-- Touch routing over an input-locked panel. The lock lives in the host routers, so `touch.candidates` alone cannot
-- see it; the case drives `poke.step` and the pointer router together.

local testing = require '@testing'
local expect = testing.expect
local panels = require '../private/panel'
local input = require '../private/input'
local touch = require '../private/touch'
local poke = require '../private/poke'

local test = testing.suite()

local function record()
  local provider = {
    env = {},
    router = input.new(),
    offer = function() end,
    release = function() end,
    changed = function() end,
    cancelContent = function() end,
    resolve = function() end,
    surfaceOf = function() end,
  }
  local target = panels.record(provider, 'touch', {}, 'fixed', 0.3, 0.2, lovr.math.newMat4():translate(0, 1.5, -1))
  return target
end

local function content(panel: any, activates: { string }): any
  return {
    id = 1,
    kind = {
      name = 'test/touch',
      registration = {
        interactive = function(): boolean
          return true
        end,
        event = function(node: any, event: any)
          table.insert(activates, event.kind)
          if event.kind == 'activate' then
            node:emit 'onActivate'
          end
        end,
      },
      composite = false,
      portal = false,
      outlet = false,
    },
    key = 'content',
    slot = 'content',
    props = {},
    state = {},
    host = { hovers = 0, pressed = false, dragging = false, focused = false, focusVisible = false, engaged = false },
    parent = nil,
    children = {},
    panel = panel,
    x = 0,
    y = 0,
    width = 0.3,
    height = 0.2,
    z = 0,
    lift = 0,
    dead = false,
    handle = { theme = { elevation = { pressTravel = 0, minimumSeparation = 0, hoverLift = 0 } } },
  }
end

local function environment(): any
  return {
    protect = function(_label: string, run: () -> ()): boolean
      run()
      return true
    end,
    blocked = function(): boolean
      return false
    end,
    pressed = function() end,
    focusNode = function(): boolean
      return false
    end,
    haptics = function(): boolean
      return false
    end,
    pulse = function() end,
  }
end

test('a touch press on locked content captures nothing and never activates', function()
  local panel = record()
  local activates: { string } = {}
  panel.root = content(panel, activates)
  panel.locked = true
  local env = environment()
  local router = input.new()
  local pointer = { source = 'touch' }
  local hand = poke.new()
  local point = vector.pack(panel.pose:mul(0, 0, 0.04))
  poke.step(hand, touch.candidates({ panel }, env, point), 0.016)
  local pressed = false
  for _, event in poke.step(hand, touch.candidates({ panel }, env, vector.pack(panel.pose:mul(0, 0, -0.01))), 0.016) do
    if event.kind == 'press' then
      pressed = true
      input.pointer(router, panel, env, { kind = 'press', pointer = pointer, x = event.x, y = event.y })
    end
  end
  expect.truthy(pressed, 'the fingertip presses')
  local state = router.pointers[pointer]
  expect.falsy(state and state.capture, 'the locked content captures nothing')
  input.pointer(router, panel, env, { kind = 'release', pointer = pointer, x = 0.15, y = 0.1 })
  expect.equal(#activates, 0, 'nothing activated')
  expect.falsy(router.pointers[pointer] and router.pointers[pointer].capture, 'the release captures nothing')
end)

return test
