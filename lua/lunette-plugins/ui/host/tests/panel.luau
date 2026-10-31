local testing = require '@testing'
local panels = require '../private/panel'
local input = require '../private/input'
local motion = require '../private/motion'
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

local function hits(surface: any): boolean
  return surface:raycast(vector.pack(0, 0, 1), vector.pack(0, 0, -1)) ~= nil
end

test('an owner opacity fades the panel and gates its input', function()
  local _, record, handle, surface = made()
  expect.truthy(hits(surface), 'an opaque panel takes rays')
  handle:setOpacity(0)
  expect.truthy(surface.dead, 'a panel fading out withdraws its surface at once')
  expect.falsy(hits(surface), 'a panel fading out takes no rays at once')
  expect.equal(record.opacity.value, 1, 'the opacity animates rather than jumping')
  motion.panel(record, 1, 0.1)
  expect.near(record.opacity.value, 0, 1e-6, 'the fade settles')
  handle:setOpacity(1)
  expect.falsy(hits(surface), 'a transparent panel fading in is not yet pressable')
  motion.panel(record, 1, 0.1)
  record.sync()
  expect.falsy(surface.dead, 'the surface returns once the panel is opaque again')
  expect.truthy(hits(surface), 'an opaque panel takes rays again')
end)

test('an owner opacity is a number from 0 to 1', function()
  local _, _, handle = made()
  for _, bad in { -0.1, 1.5, 0 / 0, 'half' :: any } do
    expect.falsy(pcall(handle.setOpacity, handle, bad), `{tostring(bad)} is refused`)
  end
end)

return test
