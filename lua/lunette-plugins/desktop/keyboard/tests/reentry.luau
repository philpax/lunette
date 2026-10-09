local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/display'
local test = testing.suite()

local function capture(board, cancel)
  local pointer
  pointer = {
    cancel = function(_self, target, reason)
      target:onPointer { kind = 'cancel', pointer = pointer, button = 'right', reason = reason }
      cancel()
    end,
  }
  board:onPointer {
    kind = 'press',
    pointer = pointer,
    button = 'right',
    x = board.width / 2,
    y = board.height / 2,
    inside = true,
    captured = true,
  }
end

test('hide cancellation selecting native focus never blurs the newer native target', function()
  local env = fixture.start()
  expect.truthy(env.first:focus())
  local board, native = fixture.shown(env), env.nativeTarget()
  capture(board, function()
    expect.truthy(native:focus())
  end)
  expect.truthy(env.display.service:hide())
  expect.equal(env.focus:focused(), native)
  expect.falsy(env.display.service:isVisible())
  env.session:close()
end)

test('hide cancellation refocusing the same local identity respects its newer revision', function()
  local env = fixture.start()
  local target = env.localTarget()
  expect.truthy(target:focus())
  local board, before = fixture.shown(env), env.focus:revision()
  capture(board, function()
    expect.truthy(target:blur())
    expect.truthy(target:focus())
  end)
  expect.falsy(env.display.service:hide(), 'a newer local focus supersedes the hide')
  expect.equal(env.focus:focused(), target)
  expect.truthy(env.focus:revision() > before)
  expect.truthy(env.display.service:isVisible())
  expect.equal(fixture.shown(env), board)
  env.session:close()
end)

test('ending automatic editing cannot hide a newer local focus selected during cancellation', function()
  local env = fixture.start()
  local first, second, native = env.localTarget(), env.localTarget(), env.nativeTarget()
  expect.truthy(first:focus())
  local board = fixture.shown(env)
  capture(board, function()
    expect.truthy(second:focus())
  end)
  expect.truthy(native:focus())
  expect.equal(env.focus:focused(), second)
  expect.equal(fixture.shown(env), board)
  expect.truthy(board.visible)
  env.session:close()
end)

test('hide cancellation can unload the display without retaining the board or callbacks', function()
  local env = fixture.start()
  expect.truthy(env.first:focus())
  local board, raw = fixture.shown(env), env.rawDisplay
  capture(board, function()
    env.session.instances['desktop/keyboard']:disable()
  end)
  expect.falsy(raw:hide())
  expect.truthy(board.dead)
  expect.equal(fixture.boardCount(env), 0)
  expect.falsy(board:typeText 'stale')
  expect.equal(env.first:value(), 'draft')
  env.session:close()
end)

test('blur checks a fresh revision after callback-capable focused inspection', function()
  local plugin = require '@lunette-plugin'
  local focus = require '@lunette-contracts/focus'
  local provider = require '@lunette-plugins/focus'
  local armed, changed = false, false
  local wrapped = plugin.define {
    name = 'testing/display-focus-query',
    requires = provider.requires,
    provides = { focus = focus.capability },
    init = function(context, _config, publish)
      local real = provider.build(context)
      local service = table.clone(real)
      service.focused = function(_self)
        local target = real:focused()
        if armed then
          armed, changed = false, true
          expect.truthy(target:blur())
          expect.truthy(target:focus())
        end
        return target
      end
      publish:provide(focus.capability, service)
    end,
  }
  local env = fixture.start { focus = { id = 'focus', definition = wrapped } }
  local target = env.localTarget()
  expect.truthy(target:focus())
  armed = true
  expect.falsy(env.rawDisplay:hide(), 'the queried target now belongs to a newer focus revision')
  expect.truthy(changed)
  expect.equal(env.focus:focused(), target)
  expect.truthy(env.rawDisplay:isVisible(), 'the newer focus remains visible')
  env.session:close()
end)

return test
