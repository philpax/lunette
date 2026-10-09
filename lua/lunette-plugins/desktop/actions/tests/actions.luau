local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local display = require '@lunette-contracts/keyboard-display'
local menu = require '@lunette-contracts/menu'
local actions = require '@lunette-plugins/desktop/actions'
local expect = testing.expect
local test = testing.suite()
local retainedMenu = require './support/retained-menu'

local function retainedRegistration(state, id)
  for index = #state.registrations, 1, -1 do
    local registration = state.registrations[index]
    if registration.action.id == id then
      return registration
    end
  end
  error('no retained registration for ' .. id)
end

local function boot(menuEntry)
  local state = { visible = false, listeners = {}, toggles = 0 }
  state.session = testing.boot {
    menuEntry or 'menu',
    {
      id = 'display',
      definition = plugin.define {
        name = 'testing/display',
        provides = { display = display.capability },
        init = function(context, _, provide)
          state.service = {
            dead = false,
            isVisible = function()
              return state.visible
            end,
            toggle = function()
              state.toggles += 1
              state:change(not state.visible)
              return true
            end,
            onChanged = function(_self, owner, listener)
              state.listeners[listener] = true
              return context:acquire(owner, function()
                return function()
                  state.listeners[listener] = nil
                end
              end)
            end,
          }
          provide:provide(display.capability, state.service)
        end,
      },
    },
    { id = 'desktop/actions', definition = actions },
  }
  state.menu = state.session:observe(menu.capability).service
  function state:change(value)
    self.visible = value
    for listener in self.listeners do
      listener.run { visible = value, reason = if value then 'show' else 'hide', revision = 1 }
    end
  end
  return state
end

local function withActions(run, menuEntry)
  local env = boot(menuEntry)
  run(env)
  env.session:close()
end

test('session actions register exact ids ordering and keyboard selected updates', function()
  withActions(function(env)
    local listed = env.menu:list()
    expect.equal(#listed, 2)
    expect.equal(listed[1].id, 'desktop/keyboard/toggle')
    expect.equal(listed[1].label, 'Keyboard')
    expect.equal(listed[1].group, 'Session')
    expect.equal(listed[1].order, 10)
    expect.equal(listed[1].selected, false)
    expect.equal(listed[2].id, 'desktop/reload')
    expect.equal(listed[2].label, 'Reload configuration')
    expect.equal(listed[2].group, 'Session')
    expect.equal(listed[2].order, 30)
    expect.equal(env.menu:invoke(listed[1].id, listed[1].registration).kind, 'invoked')
    expect.equal(env.toggles, 1)
    expect.equal(env.menu:list()[1].selected, true)
    env:change(false)
    expect.equal(env.menu:list()[1].selected, false)
    env.session.instances['desktop/actions']:disable()
    expect.equal(#env.menu:list(), 0)
    expect.equal(next(env.listeners), nil)
  end)
end)

test('reload uses the public API and logs a refusal without failing the action', function()
  withActions(function(env)
    local reload, log = lunette.reload, lovr.log
    local calls, messages = 0, {}
    lunette.reload = function()
      calls += 1
      return false, 'reload already pending'
    end
    lovr.log = function(message, level, tag)
      messages[#messages + 1] = { message, level, tag }
    end
    local result = env.menu:invoke 'desktop/reload'
    lunette.reload, lovr.log = reload, log
    expect.equal(result.kind, 'invoked')
    expect.equal(calls, 1)
    expect.equal(#messages, 1)
    expect.equal(messages[1][1], 'configuration was not reloaded: reload already pending')
    expect.equal(messages[1][2], 'error')
    expect.equal(messages[1][3], 'lunette.desktop')
    expect.equal(#testing.takeReports(), 0)
  end)
end)

test('keyboard display outage keeps the current Reload registration and public recovery action', function()
  withActions(function(env)
    local reload = lunette.reload
    local calls = 0
    lunette.reload = function()
      calls += 1
      return true
    end
    local ok, message = pcall(function()
      local before = env.menu:list()[2]
      env.session.instances.display:disable()
      local listed = env.menu:list()
      expect.equal(#listed, 1, 'only Reload remains')
      expect.equal(listed[1].id, 'desktop/reload')
      expect.equal(listed[1].registration, before.registration, 'the parent registration survives')
      expect.equal(env.session.instances['desktop/actions']:state(), 'active')
      expect.equal(next(env.listeners), nil)
      expect.equal(env.menu:invoke('desktop/reload', before.registration).kind, 'invoked')
      expect.equal(calls, 1)
      env.session.instances.display:enable()
      expect.equal(#env.menu:list(), 2)
      expect.equal(env.menu:list()[2].registration, before.registration, 'display recovery does not replace Reload')
      expect.equal(env.menu:invoke('desktop/keyboard/toggle').kind, 'invoked')
      expect.equal(env.toggles, 1)
    end)
    lunette.reload = reload
    if not ok then
      error(message, 0)
    end
  end)
end)

test('retained raw Reload callbacks reject ended owners and replacement activations', function()
  local retained = {}
  withActions(function(env)
    local function current(id)
      return retainedRegistration(retained, id)
    end
    local reload = lunette.reload
    local calls = 0
    lunette.reload = function()
      calls += 1
      return true
    end
    local ok, message = pcall(function()
      local old = current 'desktop/reload'
      old.action.run()
      expect.equal(calls, 1, 'a current callback reaches the public API')
      env.session.instances['desktop/actions']:disable()
      old.action.run()
      expect.equal(calls, 1, 'disposal ends callback authority')
      env.session.instances['desktop/actions']:enable()
      local replacement = current 'desktop/reload'
      expect.truthy(replacement.owner ~= old.owner)
      old.action.run()
      expect.equal(calls, 1, 'a new activation never revives an old callback')
      replacement.action.run()
      expect.equal(calls, 2)
      env.session:close()
      replacement.action.run()
      expect.equal(calls, 2, 'runtime closure ends callback authority')
    end)
    lunette.reload = reload
    if not ok then
      error(message, 0)
    end
  end, retainedMenu(retained))
end)

test('Keyboard uses a child owner and stale toggle and visibility callbacks remain inert', function()
  local retained = {}
  withActions(function(env)
    local reload = retainedRegistration(retained, 'desktop/reload')
    local toggle = retainedRegistration(retained, 'desktop/keyboard/toggle')
    local listener = next(env.listeners)
    expect.truthy(toggle.owner ~= reload.owner, 'the registrations have disjoint owners')
    expect.truthy(toggle.owner:active())
    toggle.action.run()
    expect.equal(env.toggles, 1)
    expect.equal(#retained.updates, 1)
    expect.equal(retained.updates[1].owner, toggle.owner, 'visibility updates use the registration owner')
    expect.equal(retained.updates[1].effect, toggle.effect)
    env.session.instances.display:disable()
    expect.equal(toggle.owner:active(), false)
    expect.equal(reload.owner:active(), true, 'display loss does not end Reload authority')
    toggle.action.run()
    listener.run { visible = true, reason = 'show', revision = 2 }
    expect.equal(env.toggles, 1)
    expect.equal(#retained.updates, 1, 'the ended listener makes no menu update')
    env.session.instances.display:enable()
    local replacement = retainedRegistration(retained, 'desktop/keyboard/toggle')
    expect.truthy(replacement.owner ~= toggle.owner)
    expect.equal(retainedRegistration(retained, 'desktop/reload'), reload)
    toggle.action.run()
    listener.run { visible = true, reason = 'show', revision = 3 }
    expect.equal(env.toggles, 1, 'recovery does not revive old toggle authority')
    expect.equal(#retained.updates, 1)
    replacement.action.run()
    expect.equal(env.toggles, 2)
    expect.equal(#retained.updates, 2)
    expect.equal(retained.updates[2].owner, replacement.owner)
    env.session.instances['desktop/actions']:disable()
    replacement.action.run()
    expect.equal(env.toggles, 2)
    expect.equal(next(env.listeners), nil)
  end, retainedMenu(retained))
end)

return test
