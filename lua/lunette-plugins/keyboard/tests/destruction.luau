local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardContract = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'

local test = testing.suite()

local function start(focusDefinition)
  testing.native()
  local focusEntry = if focusDefinition then { id = 'focus', definition = focusDefinition } else 'focus'
  local env = { session = testing.start { 'theme', focusEntry, 'keyboard' } }
  env.consumer = env.session:use(plugin.define {
    name = 'keyboard-destruction-owner',
    requires = { keyboard = keyboardContract.capability, focus = focusContract.capability },
    init = function(context)
      env.owner = context
      env.keyboard = context:require(keyboardContract.capability)
      env.focus = context:require(focusContract.capability)
    end,
  })
  return env
end

local function focusRegistrations(service)
  local sources, listeners = 0, 0
  for _, entry in service:inspect().registrations do
    if entry.source == 'focus.newSource' then
      sources += 1
    elseif entry.source == 'focus.onChanged' then
      listeners += 1
    end
  end
  return sources, listeners
end

test('built-in commits all registrations before notifying owner shutdown', function()
  local env = start()
  local callbacks, observed = 0, nil
  local board
  board = env.keyboard:new(env.owner, {
    onVisibilityChanged = function(change)
      if change.reason == 'destroy' then
        callbacks += 1
        local sources, listeners = focusRegistrations(env.focus)
        observed = {
          boards = #env.keyboard:inspect().registrations,
          sources = sources,
          listeners = listeners,
          dead = board.dead,
          visible = board.visible,
          modifiers = #board:modifiers(),
          secondDestroy = board:destroy(),
        }
        board:setVisible(true)
      end
    end,
  })
  local sources, listeners = focusRegistrations(env.focus)
  expect.equal(sources, 1, 'one board source')
  expect.equal(listeners, 1, 'the board route listener')
  board:pressKey(42)
  board:pressKey(58)
  env.consumer:disable()
  expect.equal(callbacks, 1, 'one final notification')
  expect.equal(observed.boards, 0, 'no board registration inside the destroy callback')
  expect.equal(observed.sources, 0, 'no source registration inside the destroy callback')
  expect.equal(observed.listeners, 0, 'no route listener inside the destroy callback')
  expect.truthy(observed.dead)
  expect.equal(observed.visible, false)
  expect.equal(observed.modifiers, 0)
  expect.falsy(observed.secondDestroy)
  expect.equal(board.visible, false, 'callback reentry cannot revive visibility')
  env.session:close()
  expect.equal(callbacks, 1, 'session shutdown never repeats destruction')
end)

local function faultyFocus(state)
  return plugin.define {
    name = 'keyboard-cleanup-substitute',
    provides = { focus = focusContract.capability },
    init = function(context, _settings, publish)
      publish:provide(focusContract.capability, {
        newSource = function(_self, owner)
          local source = { dead = false }
          local effect = context:acquire(owner, function()
            state.sourceCount += 1
            return function()
              source.dead = true
              state.sourceCount -= 1
              state.sourceReleases += 1
            end
          end)
          function source:destroy()
            if self.dead then
              return false
            end
            effect:dispose()
            return true
          end
          function source:reset()
            return true
          end
          function source:key()
            return { kind = 'consumed' }
          end
          return source
        end,
        onChanged = function()
          error 'listener acquisition defect'
        end,
      })
    end,
  }
end

test('a route listener acquisition failure releases the partially constructed keyboard source', function()
  local state = { sourceCount = 0, sourceReleases = 0 }
  local env = start(faultyFocus(state))
  local callbacks = 0
  expect.raises(function()
    env.keyboard:new(env.owner, {
      onVisibilityChanged = function()
        callbacks += 1
      end,
    })
  end, 'listener acquisition defect')
  expect.equal(state.sourceCount, 0)
  expect.equal(state.sourceReleases, 1)
  expect.equal(#env.keyboard:inspect().registrations, 0)
  expect.equal(callbacks, 0)
  env.session:close()
end)

return test
