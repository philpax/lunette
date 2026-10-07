local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/display'
local keyboard = require '@lunette-plugins/keyboard'
local test = testing.suite()

local function start()
  return fixture.start {
    keyboard = {
      id = 'keyboard',
      definition = keyboard.define {
        rows = { { { action = { kind = 'hide' }, label = 'hide' } } },
        layers = {},
      },
    },
  }
end

local function pressHide(board, duringCancel)
  local pointer
  pointer = {
    cancel = function(_self, target, reason)
      target:onPointer { kind = 'cancel', pointer = pointer, button = 'left', reason = reason }
      if duringCancel then
        duringCancel()
      end
    end,
  }
  board:onPointer {
    kind = 'press',
    pointer = pointer,
    button = 'left',
    x = board.width / 2,
    y = board.height / 2,
    inside = true,
    captured = true,
  }
end

test('builtin user hide clears manual intent and blurs the field before display observers', function()
  local env = start()
  expect.truthy(env.first:focus())
  expect.truthy(env.display.service:show())
  local board = fixture.shown(env)
  local changes = {}
  local effect = env.display.service:onChanged(env.display.context, {
    run = function(change)
      changes[#changes + 1] = change
      expect.equal(env.focus:focused(), nil, 'user hide blurs before display notification')
      expect.falsy(env.display.service:isVisible())
    end,
  })
  pressHide(board)
  expect.falsy(board.visible)
  expect.equal(#changes, 1)
  expect.equal(changes[1].reason, 'user-hide')
  effect:dispose()
  expect.equal(env.first:value(), 'draft', 'user hide preserves the draft')
  expect.truthy(env.first:focus())
  expect.equal(fixture.shown(env), board)
  expect.truthy(env.first:blur())
  expect.equal(fixture.shown(env), nil, 'user hide cleared manual visibility')
  env.session:close()
end)

test('builtin user hide cancellation cannot blur newer native focus', function()
  local env = start()
  expect.truthy(env.first:focus())
  local board, native = fixture.shown(env), env.nativeTarget()
  pressHide(board, function()
    expect.truthy(native:focus())
  end)
  expect.equal(env.focus:focused(), native)
  expect.falsy(env.display.service:isVisible())
  env.session:close()
end)

return test
