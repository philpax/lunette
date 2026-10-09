local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/fixture'
local test = testing.suite()

test('menu owner registration and failure lifecycle', function()
  local env = fixture.start()
  local calls = 0
  local owned = fixture.probe(env, 'menu-owned')
  local effect = owned.service:register(
    owned.owner,
    fixture.action('fixture.action', function()
      calls += 1
    end)
  )
  expect.equal(env.service:invoke('fixture.action').kind, 'invoked', 'a live action')
  expect.equal(calls, 1, 'the callback runs once')
  expect.raises(function()
    env.service:register(env.owner, fixture.action 'fixture.action')
  end, 'menu register: fixture.action is already registered', 'a globally duplicate id')
  owned.instance:disable()
  expect.equal(#env.service:list(), 0, 'owner removal removes the registration')
  expect.equal(env.service:update(owned.owner, effect, { enabled = true }), false, 'an ended owner cannot update')
  expect.equal(env.service:invoke('fixture.action').kind, 'unavailable', 'a removed action')
  expect.raises(function()
    env.service:register(owned.owner, fixture.action 'late')
  end, 'plugin', 'late registration has no owner authority')
  env.service:register(
    env.owner,
    fixture.action('fixture.action', function()
      error 'the menu callback raises'
    end)
  )
  local result = env.service:invoke 'fixture.action'
  expect.equal(result.kind, 'failed', 'a failure is explicit')
  expect.truthy(type(result.message) == 'string' and #result.message > 0, 'the result has a failure message')
  local reports = env.native.events.reported
  expect.equal(#reports, 1, 'one callback failure report')
  testing.takeReports()
  expect.truthy(reports[1].message:find('fixture.action', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('testing/observer-', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('the menu callback raises', 1, true), reports[1].message)
  expect.equal(#env.service:inspect().registrations, 1, 'failure does not dispose the registration')
  env.session:close()
end)

test('updates require the actual registering owner and effect and never create a registration', function()
  local env = fixture.start()
  local other = fixture.probe(env, 'menu-other')
  local effect = env.service:register(env.owner, fixture.action 'fixture.state')
  local foreignEffect = env.owner:effect(function()
    return function() end
  end)
  expect.equal(env.service:update(other.owner, effect, { enabled = false }), false, 'another dependent cannot update')
  expect.equal(env.service:update(env.owner, foreignEffect, { enabled = false }), false, 'an unrelated effect')
  local forged = {
    dispose = function()
      error 'a forged effect is called'
    end,
  }
  expect.equal(env.service:update(env.owner, forged, { enabled = false }), false, 'a fabricated effect')
  local state = { enabled = false, selected = true }
  expect.equal(env.service:update(env.owner, effect, state), true, 'the registering owner updates')
  state.enabled, state.selected = true, false
  local row = env.service:list()[1]
  expect.equal(row.enabled, false, 'enabled is copied')
  expect.equal(row.selected, true, 'selected is copied')
  expect.equal(env.service:invoke('fixture.state').kind, 'unavailable', 'a disabled action')
  expect.equal(env.service:update(env.owner, effect, {}), true, 'an empty update is a no-op')
  expect.equal(env.service:list()[1].enabled, false, 'omitted state preserves enabled')
  expect.equal(env.service:update(env.owner, effect, { enabled = true }), true, 'enabled changes independently')
  expect.equal(env.service:list()[1].selected, true, 'omitted state preserves selected')
  effect:dispose()
  effect:dispose()
  expect.equal(env.service:update(env.owner, effect, { enabled = true }), false, 'a disposed effect cannot update')
  expect.equal(#env.service:list(), 0, 'an update does not recreate the action')
  env.service:register(env.owner, fixture.action 'fixture.state')
  expect.equal(
    env.service:update(env.owner, effect, { enabled = false }),
    false,
    'an old effect cannot update its replacement'
  )
  expect.equal(env.service:list()[1].enabled, true, 'the replacement keeps its own state')
  env.session:close()
end)

test('a list token rejects a removed registration even after its id is reused', function()
  local env = fixture.start()
  local calls = 0
  local first = env.service:register(env.owner, fixture.action 'fixture.reused')
  local row = env.service:list()[1]
  first:dispose()
  env.service:register(
    env.owner,
    fixture.action('fixture.reused', function()
      calls += 1
    end)
  )
  local replacement = env.service:list()[1]
  expect.truthy(row.registration ~= replacement.registration, 'a replacement has a fresh token')
  expect.equal(env.service:invoke(row.id, row.registration).kind, 'unavailable', 'the stale row is rejected')
  expect.equal(
    env.service:invoke(row.id, { kind = 'menu-registration' }).kind,
    'unavailable',
    'a copied token is rejected'
  )
  expect.equal(calls, 0, 'stale tokens never invoke the replacement')
  expect.equal(env.service:invoke(replacement.id, replacement.registration).kind, 'invoked', 'the current row invokes')
  expect.equal(env.service:invoke(row.id).kind, 'invoked', 'id-only invocation retains its narrow shape')
  expect.equal(calls, 2, 'only current invocations run')
  env.session:close()
end)

test('self-disposal and replacement dispatch only the captured callback and allow explicit reentry', function()
  local env = fixture.start()
  local calls = {}
  local effect
  local token
  effect = env.service:register(
    env.owner,
    fixture.action('fixture.reentry', function()
      calls[#calls + 1] = 'original'
      effect:dispose()
      env.service:register(
        env.owner,
        fixture.action('fixture.reentry', function()
          calls[#calls + 1] = 'replacement'
        end)
      )
      expect.equal(env.service:invoke('fixture.reentry', token).kind, 'unavailable', 'reentry rejects the old token')
      expect.equal(env.service:invoke('fixture.reentry').kind, 'invoked', 'explicit reentry uses the current id')
    end)
  )
  token = env.service:list()[1].registration
  expect.equal(env.service:invoke('fixture.reentry', token).kind, 'invoked', 'the original callback completes')
  expect.equal(table.concat(calls, ','), 'original,replacement', 'replacement runs only from explicit reentry')
  env.session:close()
end)

test('self-unloading completes the captured invocation and removes all owner actions', function()
  local env = fixture.start()
  local owned = fixture.probe(env, 'menu-self-unload')
  local calls = 0
  owned.service:register(
    owned.owner,
    fixture.action('fixture.unload', function()
      owned.instance:disable()
      calls += 1
    end)
  )
  owned.service:register(owned.owner, fixture.action 'fixture.sibling')
  expect.equal(env.service:invoke('fixture.unload').kind, 'invoked', 'the captured invocation completes')
  expect.equal(calls, 1, 'self-unload calls once')
  expect.equal(#env.service:list(), 0, 'all actions owned by the unloaded plugin end')
  expect.equal(env.service:invoke('fixture.unload').kind, 'unavailable', 'the unloaded action is unavailable')
  env.session:close()
end)

test('provider recovery creates a fresh service and registration authority', function()
  local env = fixture.start()
  local owned = fixture.probe(env, 'menu-recovering', function(found)
    found.effect = found.service:register(found.owner, fixture.action 'fixture.recover')
  end)
  local oldService, oldOwner, oldEffect = owned.service, owned.owner, owned.effect
  local oldRow = oldService:list()[1]
  local list, inspect, invoke, update = oldService.list, oldService.inspect, oldService.invoke, oldService.update
  env.session.instances.menu:disable()
  expect.equal(owned.instance:state(), 'inactive', 'the dependent waits for its provider')
  expect.raises(function()
    oldService:list()
  end, 'provider activation has ended', 'the facade revokes service reads')
  expect.equal(#list(oldService), 0, 'a captured method answers an empty old service')
  expect.equal(#inspect(oldService).registrations, 0, 'inspection releases owner records')
  expect.equal(invoke(oldService, 'fixture.recover', oldRow.registration).kind, 'unavailable', 'old service invocation')
  expect.equal(update(oldService, oldOwner, oldEffect, { selected = true }), false, 'old service update')
  env.session.instances.menu:enable()
  expect.equal(owned.instance:state(), 'active', 'the dependent recovers')
  expect.truthy(owned.service ~= oldService and owned.owner ~= oldOwner, 'recovery creates fresh identities')
  expect.equal(owned.service:invoke('fixture.recover', oldRow.registration).kind, 'unavailable', 'old epoch token')
  expect.equal(owned.service:invoke('fixture.recover').kind, 'invoked', 'the recovered registration')
  env.session:close()
end)

test('a captured register method cannot acquire actions during provider cleanup', function()
  local env = fixture.start()
  env.session.instances.menu:disable()
  local attempted = false
  local provider = env.session:use(require('@lunette-plugin').define {
    name = 'menu-cleanup-provider',
    provides = { menu = require('@lunette-contracts/menu').capability },
    init = function(context, _config, publish)
      local service = require('@lunette-plugins/menu').build(context)
      local register = service.register
      publish:provide(require('@lunette-contracts/menu').capability, service)
      context:effect(function()
        return function()
          attempted = true
          expect.raises(function()
            register(service, context, fixture.action 'fixture.late-cleanup')
          end, 'menu register: the provider is inactive', 'cleanup cannot extend the provider lifetime')
        end
      end)
    end,
  })
  provider:disable()
  expect.equal(attempted, true, 'the provider inverse attempted registration')
  env.session:close()
end)

for _, ending in ipairs { 'dispose', 'owner', 'provider' } do
  test('a retained effect releases its callback after ' .. ending .. ' removal', function()
    local env = fixture.start()
    local owned = fixture.probe(env, 'menu-callback-release')
    local weak = setmetatable({}, { __mode = 'v' })
    local effect = (function()
      local payload = {}
      weak.payload = payload
      return owned.service:register(
        owned.owner,
        fixture.action('fixture.release', function()
          expect.truthy(payload, 'the callback retains its payload while live')
        end)
      )
    end)()
    testing.collect()
    expect.truthy(weak.payload, 'a live action retains its callback payload')
    if ending == 'dispose' then
      effect:dispose()
    elseif ending == 'owner' then
      owned.instance:disable()
    else
      env.session.instances.menu:disable()
    end
    testing.collect()
    expect.equal(weak.payload, nil, 'the ended action releases its callback payload')
    expect.truthy(effect, 'the caller retains the effect')
    env.session:close()
  end)
end

return test
