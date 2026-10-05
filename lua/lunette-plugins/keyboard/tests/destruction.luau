local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local keyboardContract = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'
local keyboard = require '@lunette-plugins/keyboard'

local test = testing.suite()

local function start(tiny, focusDefinition)
  local native = testing.native()
  local definition = keyboard.definition
  if tiny then
    testing.host.useConfiguration 'examples/keyboard'
    definition = require 'tiny'
  end
  local focusEntry = if focusDefinition then { id = 'focus', definition = focusDefinition } else 'focus'
  local env = {
    native = native,
    session = testing.start { focusEntry, { id = 'keyboard', definition = definition } },
  }
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

for _, tiny in { false, true } do
  local provider = if tiny then 'tiny' else 'built-in'
  for _, shutdown in { false, true } do
    local mode = if shutdown then 'owner shutdown' else 'direct destroy'
    test(provider .. ' commits all registrations before notifying ' .. mode, function()
      local env = start(tiny)
      local callbacks, observed = 0, nil
      local board
      board = env.keyboard:new(env.owner, {
        onVisibilityChanged = function(change)
          if change.reason == 'destroy' then
            callbacks += 1
            local sources, listeners = focusRegistrations(env.focus)
            observed = {
              boards = env.keyboard:inspect().logicalRegistrationCount,
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
      expect.equal(listeners, if tiny then 0 else 1, 'the board route listener')
      board:pressKey(42)
      board:pressKey(58)
      if shutdown then
        env.consumer:disable()
      else
        expect.truthy(board:destroy())
      end
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

    test(provider .. ' releases its visibility callback while the dead board remains after ' .. mode, function()
      local env = start(tiny)
      local weak = setmetatable({}, { __mode = 'v' })
      local callbacks = 0
      local board
      do
        local callback = function(change)
          if change.reason == 'destroy' then
            callbacks += 1
          end
        end
        weak.callback = callback
        board = env.keyboard:new(env.owner, { onVisibilityChanged = callback })
      end
      if shutdown then
        env.consumer:disable()
      else
        board:destroy()
      end
      testing.collect()
      expect.truthy(board.dead, 'the caller retains the dead board')
      expect.equal(weak.callback, nil, 'the retained dead board no longer owns the callback')
      expect.equal(callbacks, 1)
      env.session:close()
    end)

    test(provider .. ' reports a failing detached destroy callback once on ' .. mode, function()
      local env = start(tiny)
      local callbacks = 0
      local board = env.keyboard:new(env.owner, {
        onVisibilityChanged = function(change)
          if change.reason == 'destroy' then
            callbacks += 1
            error 'detached visibility callback failed'
          end
        end,
      })
      if shutdown then
        env.consumer:disable()
      else
        expect.truthy(board:destroy())
      end
      expect.falsy(board:destroy())
      expect.truthy(board.dead)
      local reports = env.native.events.reported
      expect.equal(#reports, 1)
      expect.truthy(reports[1].message:find('keyboard-destruction-owner', 1, true), 'the owner remains in diagnostics')
      expect.truthy(reports[1].message:find('detached visibility callback failed', 1, true))
      env.session:close()
      expect.equal(callbacks, 1)
      expect.equal(#reports, 1, 'cleanup never retries a detached callback')
    end)
  end
end

local function faultyFocus(state)
  return plugin.define {
    name = 'keyboard-cleanup-substitute',
    provides = { focus = focusContract.capability },
    init = function(context, _settings, publish)
      publish:provide(focusContract.capability, {
        newSource = function(_self, owner)
          local source = { dead = false }
          local function release()
            if source.dead then
              return
            end
            source.dead = true
            state.sourceCount -= 1
            state.sourceReleases += 1
            if state.onSourceRelease then
              state.onSourceRelease()
            end
            if state.sourceError then
              error 'source inverse defect'
            end
          end
          local effect = context:acquire(owner, function()
            state.sourceCount += 1
            return release
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
        onChanged = function(_self, owner)
          if state.listenerAcquireError then
            error 'listener acquisition defect'
          end
          return context:acquire(owner, function()
            state.listenerCount += 1
            return function()
              state.listenerCount -= 1
              state.listenerReleases += 1
              if state.listenerError then
                error 'listener inverse defect'
              end
            end
          end)
        end,
      })
    end,
  }
end

for _, tiny in { false, true } do
  local provider = if tiny then 'tiny' else 'built-in'
  test(provider .. ' completes independent cleanup and detaches the callback when inverses raise', function()
    local state = {
      sourceCount = 0,
      listenerCount = 0,
      sourceReleases = 0,
      listenerReleases = 0,
      sourceError = true,
      listenerError = not tiny,
    }
    local env = start(tiny, faultyFocus(state))
    local callbacks = 0
    local weak = setmetatable({}, { __mode = 'v' })
    local observed, board
    do
      local callback = function(change)
        if change.reason == 'destroy' then
          callbacks += 1
          observed = {
            boards = env.keyboard:inspect().logicalRegistrationCount,
            sources = state.sourceCount,
            listeners = state.listenerCount,
            dead = board.dead,
            modifiers = #board:modifiers(),
          }
        end
      end
      weak.callback = callback
      board = env.keyboard:new(env.owner, { onVisibilityChanged = callback })
    end
    board:pressKey(42)
    board:pressKey(58)
    local duringSourceCleanup
    state.onSourceRelease = function()
      duringSourceCleanup = { dead = board.dead, modifiers = #board:modifiers() }
    end
    expect.raises(function()
      board:destroy()
    end, 'source inverse defect')
    expect.equal(state.sourceReleases, 1, 'source cleanup runs despite a listener inverse failure')
    expect.equal(state.listenerReleases, if tiny then 0 else 1)
    expect.truthy(duringSourceCleanup.dead, 'death precedes source cleanup callbacks')
    expect.equal(duringSourceCleanup.modifiers, 0, 'internal input state clears before source callbacks')
    expect.equal(observed.boards, 0)
    expect.equal(observed.sources, 0)
    expect.equal(observed.listeners, 0)
    expect.truthy(observed.dead)
    expect.equal(observed.modifiers, 0)
    expect.equal(callbacks, 1)
    expect.falsy(board:destroy())
    testing.collect()
    expect.equal(weak.callback, nil, 'failed cleanup still detaches the callback')
    env.consumer:disable()
    expect.equal(env.consumer:state(), 'quarantined', 'the caller-owned board inverse retains its ownership')
    local diagnostic = env.consumer:diagnostic() or ''
    expect.truthy(diagnostic:find('keyboard-destruction-owner', 1, true))
    expect.truthy(diagnostic:find('source inverse defect', 1, true))
    if not tiny then
      expect.truthy(diagnostic:find('listener inverse defect', 1, true), 'both failures remain diagnostic')
    end
    expect.equal(#testing.takeReports(), 0, 'direct inverse failures propagate instead of duplicating reports')
    env.session:close()
    expect.equal(callbacks, 1)
  end)

  for _, sourceError in { false, true } do
    local inverse = if sourceError then 'a failing source inverse' else 'a source inverse'
    test(provider .. ' releases partial construction with ' .. inverse, function()
      local state = {
        sourceCount = 0,
        listenerCount = 0,
        sourceReleases = 0,
        listenerReleases = 0,
        sourceError = sourceError,
      }
      local env = start(tiny, faultyFocus(state))
      local callbacks = 0
      local weak = setmetatable({}, { __mode = 'v' })
      do
        local callback = function()
          callbacks += 1
        end
        weak.callback = callback
        local ok, failure = pcall(function()
          env.keyboard:new(env.owner, { pose = 'invalid pose', onVisibilityChanged = callback })
        end)
        expect.falsy(ok)
        expect.falsy(tostring(failure):find('source inverse defect', 1, true), 'the construction error remains primary')
      end
      expect.equal(state.sourceCount, 0)
      expect.equal(state.sourceReleases, 1)
      expect.equal(state.listenerCount, 0)
      expect.equal(env.keyboard:inspect().logicalRegistrationCount, 0)
      expect.equal(callbacks, 0, 'failed construction has no final visibility notification')
      testing.collect()
      expect.equal(weak.callback, nil)
      local reported = env.native.events.reported
      expect.equal(#reported, if sourceError then 1 else 0)
      if sourceError then
        expect.truthy(reported[1].message:find('source inverse defect', 1, true))
        expect.truthy(reported[1].message:find('keyboard-destruction-owner', 1, true))
        env.session.instances.keyboard:disable()
        expect.equal(env.session.instances.keyboard:state(), 'quarantined', 'the source inverse retains its owner')
        local reports = testing.takeReports()
        expect.equal(#reports, 1, 'the quarantined provider reports its unavailable dependent')
        expect.truthy(reports[1]:find('keyboard-destruction-owner', 1, true))
        expect.truthy(reports[1]:find('quarantined after a cleanup failure', 1, true))
      end
      env.session:close()
    end)
  end
end

test('a route listener acquisition failure releases the partially constructed keyboard source', function()
  local state = {
    sourceCount = 0,
    listenerCount = 0,
    sourceReleases = 0,
    listenerReleases = 0,
    listenerAcquireError = true,
  }
  local env = start(false, faultyFocus(state))
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
  expect.equal(state.listenerCount, 0)
  expect.equal(env.keyboard:inspect().logicalRegistrationCount, 0)
  expect.equal(callbacks, 0)
  env.session:close()
end)

return test
