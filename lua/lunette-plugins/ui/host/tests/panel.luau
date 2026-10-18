local testing = require '@testing'
local panels = require '../private/panel'
local input = require '../private/input'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local function made(): (any, any, any, any, () -> (number, number))
  local releases, unmounts = 0, 0
  local record
  local provider = {
    env = {
      protect = function(_label: string, run: () -> ()): boolean
        run()
        return true
      end,
    },
    router = input.new(),
    offer = function() end,
    release = function()
      releases += 1
    end,
  }
  local handle, surface
  record, handle, surface = panels.new(provider, {}, { name = 'liveness', width = 0.2, height = 0.1 })
  handle.root:bind {
    render = function() end,
    unmount = function()
      unmounts += 1
      expect.truthy(handle.dead, 'the public handle is dead before foreign cleanup')
      expect.truthy(surface.dead, 'the surface is dead before foreign cleanup')
      panels.destroy(provider, record)
    end,
  }
  return provider, record, handle, surface, function(): (number, number)
    return releases, unmounts
  end
end

test('private and public panel destruction publish liveness and clean up only once', function()
  for _, public in { false, true } do
    local provider, record, handle, surface, counts = made()
    if public then
      handle:destroy()
    else
      panels.destroy(provider, record)
    end
    expect.truthy(handle.dead, 'every destruction path publishes handle liveness')
    expect.truthy(surface.dead, 'every destruction path publishes surface liveness')
    handle:destroy()
    panels.destroy(provider, record)
    local releases, unmounts = counts()
    expect.equal(releases, 1, 'one release')
    expect.equal(unmounts, 1, 'one unmount even when it destroys reentrantly')
  end
end)

test('host shutdown marks retained public handles and surfaces dead', function()
  local state = fixture.boot { width = 0.2, height = 0.1 }
  local surface = fixture.surface(state)
  state.fixture:close()
  expect.truthy(state.panel.dead, 'the public handle observes shutdown')
  expect.truthy(surface.dead, 'the offered surface observes shutdown')
end)

test('internal fade destruction publishes surface liveness without a public handle', function()
  local provider, _, _, _, counts = made()
  local record = panels.record('overlay', {}, 'fixed', 0.2, 0.1, nil)
  local surface = panels.surface(provider, record, nil)
  record.closing = true
  panels.destroy(provider, record)
  expect.truthy(surface.dead, 'internal destruction synchronizes the surface')
  panels.destroy(provider, record)
  local releases = counts()
  expect.equal(releases, 1, 'internal cleanup is idempotent')
end)

return test
