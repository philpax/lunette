local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/display'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/keyboard'
local keyboard = require '@lunette-plugins/keyboard'
local test = testing.suite()

local function withEnv(env, run)
  local ok, failure = pcall(function()
    run(env)
  end)
  local closed, cleanup = pcall(function()
    env.session:close()
  end)
  if not ok then
    error(failure, 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end

for _, mode in { 'field focus', 'manual show' } do
  test('keyboard acquisition reconciles a newer ' .. mode .. ' with one visible board', function()
    local env, creations = nil, 0
    local provider = plugin.define {
      name = 'testing/display-acquisition-reentry',
      requires = keyboard.requires,
      provides = { keyboard = contract.capability },
      init = function(context, _config, publish)
        local real = keyboard.build(context)
        publish:provide(contract.capability, {
          inspect = function(_self)
            return real:inspect()
          end,
          new = function(_self, owner, options)
            creations += 1
            if mode == 'field focus' then
              env.second:focus()
            else
              env.rawDisplay:show()
            end
            return real:new(owner, options)
          end,
        })
      end,
    }
    env = fixture.start { keyboard = { id = 'keyboard', definition = provider } }
    withEnv(env, function()
      local changes = {}
      env.display.service:onChanged(env.display.context, {
        run = function(change)
          changes[#changes + 1] = change
        end,
      })
      expect.truthy(env.first:focus())
      local board = fixture.shown(env)
      expect.truthy(board and board.visible, 'the newest visible request is reconciled after acquisition')
      expect.equal(creations, 1, 'reentry never acquires a second board')
      expect.equal(fixture.boardCount(env), 1)
      expect.truthy(env.display.service:isVisible())
      expect.equal(#changes, 1, 'only the final show transition notifies')
      expect.equal(changes[1].reason, 'show')
      expect.truthy(board:typeText '!')
      if mode == 'field focus' then
        expect.equal(env.first:value(), 'draft')
        expect.equal(env.second:value(), '!', 'the newer field retains focus')
      else
        expect.equal(env.first:value(), 'draft!')
        expect.truthy(env.first:blur())
        expect.equal(fixture.shown(env), board, 'the newer manual request retains manual visibility')
      end
    end)
  end)
end

for _, method in { 'hide', 'toggle' } do
  test('public ' .. method .. ' observers see committed blur and can focus a newer field', function()
    withEnv(fixture.start(), function(env)
      expect.truthy(env.first:focus())
      local board = fixture.shown(env)
      local snapshots, changes = {}, {}
      env.display.service:onChanged(env.display.context, {
        run = function(change)
          changes[#changes + 1] = change
          if change.reason == 'hide' then
            snapshots[#snapshots + 1] = {
              focused = env.focus:focused(),
              visible = env.display.service:isVisible(),
              notificationVisible = change.visible,
            }
            env.second:focus()
          end
        end,
      })
      expect.falsy(env.display.service[method](env.display.service), 'observer focus supersedes the hidden result')
      expect.equal(#snapshots, 1, 'one current hide notification')
      expect.equal(snapshots[1].focused, nil, 'blur completes before the display observer')
      expect.falsy(snapshots[1].visible)
      expect.falsy(snapshots[1].notificationVisible)
      expect.equal(#changes, 2, 'the observer focus publishes one new show')
      expect.equal(changes[2].reason, 'show')
      expect.equal(fixture.shown(env), board)
      expect.truthy(board:typeText '!')
      expect.equal(env.first:value(), 'draft', 'the old field remains blurred')
      expect.equal(env.second:value(), '!', 'the observer-selected field is not blurred by the older hide')
    end)
  end)
end

test('public hide suppresses its obsolete notification when cancellation selects native focus', function()
  withEnv(fixture.start(), function(env)
    expect.truthy(env.first:focus())
    local board, native = fixture.shown(env), env.nativeTarget()
    local changes = {}
    env.display.service:onChanged(env.display.context, {
      run = function(change)
        changes[#changes + 1] = change
      end,
    })
    local pointer
    pointer = {
      cancel = function(_self, target, reason)
        target:onPointer { kind = 'cancel', pointer = pointer, button = 'right', reason = reason }
        native:focus()
      end,
    }
    board:onPointer {
      kind = 'press',
      pointer = pointer,
      button = 'right',
      x = board.width / 2,
      y = board.height / 2,
      captured = true,
      inside = true,
    }
    expect.truthy(env.display.service:hide())
    expect.equal(env.focus:focused(), native)
    expect.falsy(env.display.service:isVisible())
    expect.equal(#changes, 0, 'a superseded public hide does not publish its deferred notification')
  end)
end)

test('a newer automatic hide notifies after cancellation supersedes a public hide', function()
  withEnv(fixture.start(), function(env)
    local first, second = env.localTarget(), env.localTarget()
    expect.truthy(first:focus())
    local board = fixture.shown(env)
    local changes = {}
    env.display.service:onChanged(env.display.context, {
      run = function(change)
        changes[#changes + 1] = change
      end,
    })
    local pointer
    pointer = {
      cancel = function(_self, target, reason)
        target:onPointer { kind = 'cancel', pointer = pointer, button = 'right', reason = reason }
        expect.truthy(second:focus())
        expect.truthy(second:blur())
      end,
    }
    board:onPointer {
      kind = 'press',
      pointer = pointer,
      button = 'right',
      x = board.width / 2,
      y = board.height / 2,
      captured = true,
      inside = true,
    }
    expect.truthy(env.display.service:hide())
    expect.equal(#changes, 2, 'the newer show and automatic hide both notify')
    expect.equal(changes[1].reason, 'show')
    expect.truthy(changes[1].visible)
    expect.equal(changes[2].reason, 'hide')
    expect.falsy(changes[2].visible)
    expect.equal(env.focus:focused(), nil)
    expect.falsy(env.display.service:isVisible())
    expect.equal(fixture.boardCount(env), 1, 'the hidden board remains the only instance')
  end)
end)

return test
