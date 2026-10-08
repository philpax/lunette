local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'
local keyboardContract = require '@lunette-contracts/keyboard'
local keyboard = require '@lunette-plugins/keyboard'

local test = testing.suite()

local function start(definition)
  local native = testing.native()
  local env = { native = native, activations = {}, texts = {}, listeners = {}, sources = {}, result = 'consumed' }
  local seat = { dead = false }
  function seat:characterFor(code)
    return if code == 30 then 'layout-a' else nil
  end
  function seat:symbolFor()
    return nil
  end
  env.seat = seat
  local focusProvider = plugin.define {
    name = 'keyboard-route-substitute',
    provides = { focus = focusContract.capability },
    init = function(context, _config, publish)
      publish:provide(focusContract.capability, {
        newSource = function(_self, owner, options)
          expect.equal(options.mode, 'virtual', 'the source mode')
          local source = { dead = false, resets = 0, options = options }
          function source:key(activation)
            if env.changeOnKey then
              env:change()
            end
            env.activations[#env.activations + 1] = activation
            return { kind = env.result, message = 'substitute refusal' }
          end
          function source:text(text)
            env.texts[#env.texts + 1] = text
            return { kind = env.result, message = 'substitute refusal' }
          end
          function source:keymapSeat()
            return env.seat
          end
          function source:reset()
            self.resets += 1
            return not self.dead
          end
          function source:destroy()
            if self.dead then
              return false
            end
            self.dead = true
            return true
          end
          context:acquire(owner, function()
            return function()
              source:destroy()
            end
          end)
          env.sources[#env.sources + 1] = source
          return source
        end,
        onChanged = function(_self, owner, listener)
          return context:acquire(owner, function()
            env.listeners[listener] = true
            return function()
              env.listeners[listener] = nil
            end
          end)
        end,
      })
    end,
  }
  env.session = testing.start {
    'theme',
    { id = 'focus', definition = focusProvider },
    { id = 'keyboard', definition = definition or keyboard.definition },
  }
  env.consumer = env.session:use(plugin.define {
    name = 'keyboard-route-owner',
    requires = { keyboard = keyboardContract.capability },
    init = function(context)
      env.owner, env.service = context, context:require(keyboardContract.capability)
    end,
  })
  function env:change()
    for listener in self.listeners do
      listener.run { target = nil, revision = 2, kind = 'none', wantsKeyboard = false }
    end
  end
  return env
end

local function action(board, kind)
  for _, key in board:keys() do
    if key.action and key.action.kind == kind then
      board:onPress(key.x + key.width / 2, key.y + key.height / 2, {})
      return
    end
  end
  error('no action named ' .. kind)
end

test('one owned source handles keys, text, chords, and legends without native routing', function()
  local env = start()
  local target = function()
    error 'the keyboard must leave native targeting to its source'
  end
  local board = env.service:new(env.owner, {
    target = target,
    rows = {
      {
        { code = 30 },
        { action = { kind = 'text', text = 'committed' } },
        { action = { kind = 'chord', code = 20, modifiers = { 'control', 'alt' } } },
      },
    },
  })
  expect.equal(#env.sources, 1, 'one source per keyboard')
  expect.equal(env.sources[1].options.nativeTarget, target, 'the native-only adapter reaches the source')
  expect.equal(board:keys()[1].legend, 'layout-a', 'the source supplies the keymap seat')
  expect.truthy(board:pressKey(30), 'a consumed activation')
  expect.equal(env.activations[1].code, 30)
  expect.equal(env.activations[1].isRepeat, false)
  expect.equal(#env.texts, 0, 'key legends are never committed text')
  expect.truthy(board:typeText 'direct')
  action(board, 'text')
  action(board, 'chord')
  expect.equal(table.concat(env.texts, ','), 'direct,committed')
  expect.equal(env.activations[2].code, 20)
  expect.equal(table.concat(env.activations[2].modifiers, '+'), 'control+alt')
  expect.truthy(board:destroy())
  expect.truthy(env.sources[1].dead, 'destroy releases the source')
  expect.equal(next(env.listeners), nil, 'destroy unregisters route changes')
  env.session:close()
end)

test('a route notification immediately clears locks and latches', function()
  local env = start()
  local board = env.service:new(env.owner)
  board:pressKey(42)
  board:pressKey(58)
  expect.equal(table.concat(board:modifiers(), '+'), 'shift+capsLock')
  env:change()
  expect.equal(#board:modifiers(), 0, 'no draw or next activation is needed to clear modifiers')
  expect.truthy(env.sources[1].resets > 0, 'the route change resets the source')
  env.session:close()
end)

for _, result in { 'unhandled', 'failed', 'refused' } do
  test('an ' .. result .. ' activation consumes a latch but retains a lock on the same route', function()
    local env = start()
    local board = env.service:new(env.owner)
    board:pressKey(42)
    board:pressKey(58)
    env.result = result
    expect.falsy(board:pressKey(30))
    expect.equal(table.concat(env.activations[1].modifiers, '+'), 'shift+capsLock')
    expect.equal(table.concat(board:modifiers(), '+'), 'capsLock')
    env.session:close()
  end)
end

test('visibility notifications name actual transitions and destroy follows committed state', function()
  local env = start()
  local changes = {}
  local board
  board = env.service:new(env.owner, {
    rows = { { { action = { kind = 'hide' } } } },
    onVisibilityChanged = function(change)
      expect.equal(board.visible, change.visible, 'visibility is committed before notification')
      if change.reason == 'destroy' then
        expect.truthy(board.dead, 'death is committed before notification')
      end
      changes[#changes + 1] = change.reason
    end,
  })
  board:setVisible(true)
  board:setVisible(false)
  board:setVisible(false)
  board:setVisible(true)
  action(board, 'hide')
  board:destroy()
  board:setVisible(true)
  board:destroy()
  expect.equal(table.concat(changes, ','), 'hide,show,user-hide,destroy')
  env.session:close()
end)

test('visibility callback failures report the owner and do not undo state', function()
  local env = start()
  local board = env.service:new(env.owner, {
    onVisibilityChanged = function()
      error 'visibility callback defect'
    end,
  })
  board:setVisible(false)
  expect.equal(board.visible, false)
  local reports = env.native.events.reported
  expect.equal(#reports, 1)
  expect.truthy(reports[1].message:find('keyboard-route-owner', 1, true), 'the callback owner is named')
  expect.truthy(reports[1].message:find('visibility callback defect', 1, true))
  expect.truthy(#reports[1].traceback > 0, 'the callback retains its traceback')
  expect.truthy(board:destroy())
  expect.truthy(board.dead)
  expect.equal(#reports, 2, 'destroy errors are reported once')
  env.session:close()
end)

test('the tiny substitute shares source routing and actual visibility notifications', function()
  testing.host.useConfiguration 'examples/keyboard'
  local env = start(require 'tiny')
  local changes = {}
  local target = function()
    error 'tiny must leave targeting to its source'
  end
  local board = env.service:new(env.owner, {
    target = target,
    onVisibilityChanged = function(change)
      changes[#changes + 1] = change.reason
    end,
  })
  expect.equal(#env.sources, 1)
  expect.equal(env.sources[1].options.nativeTarget, target)
  expect.truthy(board:pressKey(21))
  expect.equal(env.activations[1].code, 21)
  expect.truthy(board:typeText 'tiny text')
  expect.equal(env.texts[1], 'tiny text')
  board:setVisible(false)
  board:setVisible(false)
  board:setVisible(true)
  expect.truthy(board:destroy())
  expect.truthy(env.sources[1].dead)
  expect.equal(table.concat(changes, ','), 'hide,show,destroy')
  expect.equal(env.service:inspect().logicalRegistrationCount, 0)
  expect.falsy(board:pressKey(21))
  expect.falsy(board:destroy())
  env.session:close()
end)

test('owner shutdown destroys its board before the final visibility notification', function()
  local env = start()
  local changes = {}
  local board
  board = env.service:new(env.owner, {
    onVisibilityChanged = function(change)
      changes[#changes + 1] = change.reason
      if change.reason == 'destroy' then
        expect.truthy(board.dead)
        expect.equal(board.visible, false)
        expect.falsy(board:destroy(), 'notification reentry cannot destroy twice')
      end
    end,
  })
  env.consumer:disable()
  expect.truthy(board.dead)
  expect.truthy(env.sources[1].dead)
  expect.equal(next(env.listeners), nil)
  expect.equal(table.concat(changes, ','), 'destroy')
  expect.equal(env.service:inspect().logicalRegistrationCount, 0)
  env.session:close()
end)

test('a route changed during source selection cannot inherit keyboard locks', function()
  local env = start()
  local board = env.service:new(env.owner)
  board:pressKey(42)
  board:pressKey(58)
  env.changeOnKey = true
  expect.truthy(board:pressKey(30))
  expect.equal(#env.activations[1].modifiers, 0, 'the source receives no modifiers from the prior route')
  expect.equal(#board:modifiers(), 0)
  env.session:close()
end)

return test
