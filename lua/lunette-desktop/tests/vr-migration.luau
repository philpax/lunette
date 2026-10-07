-- The real manager and form share input across provider outages and production source reloads.
local testing = require '@testing'
local expect = testing.expect
local lunette = require '@lunette'
local scenario = require './support/vr-migration/scenario'

local test = testing.suite()
local configuration = 'lua/lunette-desktop/tests/support/vr-migration'

local function withSession(provider, run)
  local env = scenario.boot(provider)
  local ok, problem = pcall(run, env)
  local closed, failure = pcall(env.session.close, env.session)
  if not ok then
    error(tostring(problem) .. (if closed then '' else '; cleanup: ' .. tostring(failure)), 0)
  end
  if not closed then
    error(failure, 0)
  end
end

local function withdrawingUi(id)
  return id == 'ui' or id == 'focus' or id == 'menu' or id == 'frame'
end

local function providerDefinition(id, substituteUi)
  if id == 'ui' and substituteUi then
    return require('@testing/ui-substitute').definition
  end
  local module = require('@lunette-plugins/' .. id)
  return if module.definition then module.definition else module
end

local function retainedInvoke(env, id)
  local actions = env.services.menu
  local invoke = actions.invoke
  local registration = scenario.action(env, id).registration
  return function()
    return invoke(actions, id, registration)
  end
end

local function assertTerminalCallbacks(ledger, before, context)
  for index = before + 1, #ledger.events do
    local event = ledger.events[index]
    expect.truthy(event.ownerActive, context .. ': teardown callbacks belong only to a live owner')
    expect.truthy(
      event.kind == 'cancel' or event.kind == 'leave',
      context .. ': teardown delivers only terminal events'
    )
  end
end

local function assertEnded(env, saved, context)
  expect.truthy(saved.panel.dead and saved.button.dead and saved.region.dead, context .. ': retained controls are dead')
  expect.truthy(saved.target.dead, context .. ': the retained focus target is dead')
  expect.falsy(saved.target:focus(), context .. ': the stale target cannot acquire focus')
  expect.falsy(saved.button:destroy(), context .. ': stale controls cannot dispose replacements')
  expect.equal(saved.invoke().kind, 'unavailable', context .. ': the stale menu registration is inert')
  local before = env.ledger.actions
  saved.panel:draw(env.native.events.pass)
  expect.equal(env.ledger.actions, before, context .. ': retained callbacks cannot run')
end

test('VR input outage substitution matrix', function()
  for _, provider in { 'built-in', 'substitute' } do
    withSession(provider, function(env)
      local window
      for _, id in { 'ui', 'focus', 'menu', 'keyboard', 'desktop/keyboard', 'frame' } do
        local context = provider .. ', ' .. id
        env.context = context
        window = scenario.exercise(env, window)
        local uiEnds = withdrawingUi(id)
        local saved = {
          panel = env.services.probe.panel,
          button = env.services.probe.button,
          region = env.services.probe.region,
          target = env.services.focus:focused(),
          invoke = retainedInvoke(env, if uiEnds then 'example/ui/open' else 'desktop/keyboard/toggle'),
        }
        local previous = scenario.description(env, 'example/ui/form').generation
        local previousOwner = saved.button.owner
        local board
        for _, surface in env.services.surfaces:all() do
          if surface.keys and surface.setVisible then
            board = surface
          end
        end
        assert(board, 'editing has an actual keyboard before the outage')
        if uiEnds then
          scenario.capture(env, 'vr-migration-probe', 'capture')
          expect.truthy(env.ledger.pointer.hovered, context .. ': a real pointer captures the region')
        else
          scenario.capture(env, 'example/ui/form', 'preview')
          env.controls:button('right', 'trigger', false)
          env.controls:step()
        end
        local pointer = env.ledger.pointer
        local oldLedger = env.ledger
        local oldActivation = oldLedger.activations
        local releases, events = env.ledger.releases, #env.ledger.events
        local invokeOld = saved.invoke
        -- Mandatory recovery entries cannot be disabled through management; raw instances exercise the provider boundary.
        local instance = env.session.instances[id]
        instance:disable()
        if uiEnds then
          assertEnded(env, saved, context)
          env.controls:step()
          expect.truthy(
            pointer.dead or pointer.hovered == nil,
            context .. ': withdrawal cancels the real pointer capture'
          )
          expect.equal(env.ledger.releases, releases, context .. ': withdrawal never completes the old gesture')
          assertTerminalCallbacks(env.ledger, events, context)
        else
          expect.truthy(board.dead, context .. ': the withdrawn keyboard surface is dead')
          expect.falsy(saved.panel.dead, context .. ': the unrelated UI generation stays live')
          expect.equal(invokeOld().kind, 'unavailable', context .. ': the ended Keyboard menu action is inert')
        end
        instance:dispose()
        local replacement = env.session:use(providerDefinition(id, id == 'ui' and provider == 'built-in'))
        env.session.instances[id] = replacement
        if uiEnds then
          expect.truthy(
            env.services.probe.button.owner ~= previousOwner,
            context .. ': recovery exposes a new public control owner'
          )
          if id == 'ui' or id == 'focus' then
            expect.truthy(
              scenario.description(env, 'example/ui/form').generation ~= previous,
              context .. ': provider recovery exposes a new public generation'
            )
          end
          expect.equal(invokeOld().kind, 'unavailable', context .. ': old rows cannot invoke replacement actions')
          local endedEvents = #oldLedger.events
          env.controls:step()
          for eventIndex = endedEvents + 1, #oldLedger.events do
            local event = oldLedger.events[eventIndex]
            expect.truthy(event.activation ~= oldActivation, context .. ': no callback reaches an ended owner')
            expect.truthy(event.ownerActive, context .. ': replacement callbacks belong only to live owners')
          end
          expect.equal(oldLedger.releases, releases, context .. ': a held trigger cannot release into replacements')
        end
        scenario.resetHands(env)
        scenario.search(env)
        scenario.key(env)
        scenario.form(env)
        local beforeText = scenario.status(env):match 'name: (.-);'
        scenario.key(env)
        expect.equal(
          scenario.status(env):match 'name: (.-);',
          beforeText .. 'q',
          context .. ': fresh geometry restores form typing'
        )
        scenario.resources(env, context)
        env.controls:clickControl(env.services.ui, 'example/ui/form', 'close')
        if scenario.description(env, 'desktop/manager').visible then
          env.controls:clickControl(env.services.ui, 'desktop/manager', 'close')
        end
      end
    end)
  end
end)

test('VR UI ten source reloads', function()
  local native = testing.native()
  testing.host.useConfiguration(configuration)
  for _, provider in { 'built-in', 'substitute' } do
    _G.vrMigrationProvider = provider
    if provider == 'built-in' then
      require 'main'
      lovr.load()
    else
      local loaded, failure = lunette.reload()
      expect.truthy(loaded, tostring(failure))
    end
    local env = scenario.attach(native)
    local window = native.events.windows[1]
    for cycle = 1, 10 do
      local context = provider .. ', source reload ' .. cycle
      window = scenario.exercise(env, window)
      if cycle % 2 == 1 then
        scenario.search(env)
      else
        env.controls:clickControl(env.services.ui, 'example/ui/form', 'name')
      end
      scenario.key(env)
      local saved = {
        panel = env.services.probe.panel,
        button = env.services.probe.button,
        region = env.services.probe.region,
        target = assert(env.services.focus:focused()),
        invoke = retainedInvoke(env, 'example/ui/open'),
      }
      local previous = scenario.description(env, 'example/ui/form').generation
      local display, show = env.services.display, env.services.display.show
      local oldLedger = env.ledger
      scenario.capture(env, 'vr-migration-probe', 'capture')
      local pointer = assert(oldLedger.pointer)
      local events, releases = #oldLedger.events, oldLedger.releases
      local enumerations = native.events.enumerations
      local loaded, failure = lunette.reload()
      expect.truthy(loaded, context .. ': ' .. tostring(failure))
      expect.truthy(pointer.dead, context .. ': source reload cancels and releases the real pointer')
      expect.equal(oldLedger.releases, releases, context .. ': source reload cannot finish the old capture')
      assertTerminalCallbacks(oldLedger, events, context)
      expect.equal(oldLedger.ended, oldLedger.activations, context .. ': all previous probe activations release')
      expect.falsy(show(display), context .. ': the cached keyboard-display method is inert')
      scenario.refresh(env)
      assertEnded(env, saved, context)
      expect.truthy(
        scenario.description(env, 'example/ui/form').generation ~= previous,
        context .. ': public descriptions identify the replacement generation'
      )
      expect.equal(native.events.enumerations, enumerations + 1, context .. ': production reload adopts once')
      env.controls:step()
      expect.equal(env.ledger.releases, 0, context .. ': the held trigger cannot complete on the replacement')
      scenario.resetHands(env)
      scenario.resources(env, context)
      expect.equal(env.controls:draw(), false, context .. ': the reloaded desktop draws normally')
    end
  end
  expect.equal(lovr.quit(), false, 'normal quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the production session shuts down without reports')
  native.assertResourcesReleased()
  _G.vrMigration, _G.vrMigrationProvider = nil, nil
end)

return test
