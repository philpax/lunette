local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local focusContract = require '@lunette-contracts/focus'
local keyboardContract = require '@lunette-contracts/keyboard'
local keyboard = require '@lunette-plugins/keyboard'

local test = testing.suite()

local function start()
  testing.native()
  local env = { activations = {}, texts = {}, listeners = {}, sources = {}, result = 'consumed' }
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
    { id = 'keyboard', definition = keyboard.definition },
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
      board:onPointer {
        kind = 'press',
        pointer = {},
        button = 'left',
        x = key.x + key.width / 2,
        y = key.y + key.height / 2,
        inside = true,
        captured = false,
      }
      return
    end
  end
  error('no action named ' .. kind)
end

test('one owned source handles keys, text, chords, and legends without native routing', function()
  local env = start()
  local board = env.service:new(env.owner, {
    rows = {
      {
        { code = 30 },
        { action = { kind = 'text', text = 'committed' } },
        { action = { kind = 'chord', code = 20, modifiers = { 'control', 'alt' } } },
      },
    },
  })
  expect.equal(#env.sources, 1, 'one source per keyboard')
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

test('an unhandled, failed, or refused activation consumes a latch but retains a lock on the same route', function()
  for _, result in { 'unhandled', 'failed', 'refused' } do
    local env = start()
    local board = env.service:new(env.owner)
    board:pressKey(42)
    board:pressKey(58)
    env.result = result
    expect.falsy(board:pressKey(30), result)
    expect.equal(table.concat(env.activations[1].modifiers, '+'), 'shift+capsLock', result)
    expect.equal(table.concat(board:modifiers(), '+'), 'capsLock', result)
    env.session:close()
  end
end)

test('visibility notifications name actual transitions and owner shutdown follows committed state', function()
  local env = start()
  local changes = {}
  local board
  board = env.service:new(env.owner, {
    rows = { { { action = { kind = 'hide' } } } },
    onVisibilityChanged = function(change)
      expect.equal(board.visible, change.visible, 'visibility is committed before notification')
      if change.reason == 'destroy' then
        expect.truthy(board.dead, 'death is committed before notification')
        expect.falsy(board:destroy(), 'notification reentry cannot destroy twice')
      end
      changes[#changes + 1] = change.reason
    end,
  })
  board:setVisible(true)
  board:setVisible(false)
  board:setVisible(false)
  board:setVisible(true)
  action(board, 'hide')
  env.consumer:disable()
  board:setVisible(true)
  expect.falsy(board:destroy())
  expect.truthy(env.sources[1].dead)
  expect.equal(next(env.listeners), nil)
  expect.equal(table.concat(changes, ','), 'hide,show,user-hide,destroy')
  expect.equal(#env.service:inspect().registrations, 0)
  env.session:close()
end)

return test
