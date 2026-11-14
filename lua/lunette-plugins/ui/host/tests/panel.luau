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
    changed = function() end,
    cancelContent = function() end,
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
  local record = panels.record(provider, 'overlay', {}, 'fixed', 0.2, 0.1, nil)
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

test('a size from a two-handed grab zooms the panel, and hits follow the zoom', function()
  local _, record, _, surface = made()
  surface:setSize(0.4)
  expect.near(record.scale, 2, 1e-9, 'twice the width is twice the zoom')
  expect.near(surface.width, 0.4, 1e-9, 'the surface reports the zoomed width')
  expect.near(surface.height, 0.2, 1e-9, 'and keeps the proportions')
  expect.near(record.width, 0.2, 1e-9, 'layout keeps its unscaled width')
  local u, v, distance = surface:raycast(vector.pack(0.15, 0, 1), vector.pack(0, 0, -1))
  assert(u and v and distance, 'a ray beyond the unscaled edge but inside the zoomed one hits')
  expect.near(u, 0.175, 1e-6, 'panel coordinates stay unscaled')
  expect.near(distance, 1, 1e-6, 'the distance is in world metres')
  surface:setSize(0)
  expect.near(record.scale, 2, 1e-9, 'a size of zero is ignored')
end)

test('a panel publishes its curve, locks, and properties, and only commits notify', function()
  local state = fixture.boot { width = 0.3, height = 0.2 }
  local uiHost = require '@lunette-contracts/ui-host'
  local changes: { string } = {}
  state.service:onPropertiesChanged(state.owner, {
    run = function(changed: uiHost.Panel)
      table.insert(changes, changed.name)
    end,
  })
  local panel = state.panel
  expect.equal(panel:curve(), 0, 'flat by default')
  panel:setCurve(0.5, 0.25, false)
  expect.near(panel:curve(), 0.5, 1e-9, 'a preview applies the curve')
  expect.near(panel:curveAxis(), 0.25, 1e-9, 'the axis applies')
  expect.equal(#changes, 0, 'a preview does not notify')
  panel:setCurve(0.5, 0.25, true)
  expect.equal(#changes, 1, 'a commit notifies even for the same value')
  panel:setTransformLocked(true)
  expect.truthy(panel:transformLocked(), 'the transform lock applies')
  expect.truthy(fixture.surface(state).transformLocked, 'the surface publishes the transform lock')
  expect.equal(#changes, 2, 'the transform toggle notifies')
  panel:setLocked(true)
  expect.truthy(panel:locked(), 'the input lock applies')
  expect.falsy(fixture.surface(state).locked, 'the input lock stays off the surface')
  expect.equal(#changes, 3, 'the input toggle notifies')
  local properties = panel:properties()
  expect.near(properties.curve, 0.5, 1e-9, 'the shared value curve')
  expect.near(properties.curveAxis, 0.25, 1e-9, 'the shared value axis')
  expect.truthy(properties.inputLocked, 'the shared value input lock')
  expect.truthy(properties.transformLocked, 'the shared value transform lock')
  state.fixture:close()
end)

test('a toolkit panel normalises its curve axis', function()
  local state = fixture.boot { width = 0.3, height = 0.2 }
  state.panel:setCurve(0.5, 5, false)
  expect.near(state.panel:curveAxis(), 5 - 2 * math.pi, 1e-9, 'setCurve normalises the axis')
  state.panel:setCurve(0.5, -math.pi, false)
  expect.near(state.panel:curveAxis(), math.pi, 1e-9, 'a half turn from below normalises too')
  state.fixture:close()
end)

test('the bend read clamps at the shared half-turn limit', function()
  local state = fixture.boot { width = 0.3, height = 0.2 }
  local uiHost = require '@lunette-contracts/ui-host'
  local seen: uiHost.Bend? = nil
  state.service:registerKind(state.owner, {
    name = 'test/bend',
    expand = function(
      _props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      act.setCurve(100, 0, false)
      seen = act.bend()
      return nil
    end,
  })
  fixture.show(state, uiHost.element 'test/bend')
  local bend = assert(seen)
  expect.near(bend.curve, 2 * math.pi / 0.3, 1e-6, 'the width wraps one circumference')
  expect.near(state.panel:curve(), 100, 1e-9, 'the panel keeps the asked-for curve')
  state.fixture:close()
end)

test('a transform-locked toolkit panel refuses a grab and resize but its owner can pose and size', function()
  local state = fixture.boot { width = 0.3, height = 0.2 }
  local interaction = require '@lunette-contracts/interaction'
  local observed = assert(state.fixture.session):observe(interaction.capability)
  local pointer = assert(observed.service):newPointer(assert(observed.context))
  local surface = fixture.surface(state)
  local geometry = fixture.geometry(state)
  local px, py, pz = geometry.pose:mul(0, 0, 1)
  local frame = {
    origin = vector.pack(px, py, pz),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4(),
    buttons = {},
    grip = true,
  }
  pointer:update(frame, { surface })
  expect.equal(pointer.grabbed, surface, 'an unlocked panel is grabbable')
  pointer:endGrab()
  state.panel:setTransformLocked(true)
  pointer:update(frame, { surface })
  expect.falsy(pointer.grabbed, 'the transform lock refuses a grip')
  expect.falsy(pointer:beginGrab(surface, lovr.math.newMat4()), 'a direct grab is refused too')
  local width = state.panel:size()
  state.panel:setSize(state.panel:size() + 0.1, nil)
  expect.near(select(1, state.panel:size()), width + 0.1, 1e-9, 'the owner can still size the panel')
  state.panel:setPose(lovr.math.newMat4():translate(0, 1.4, -1))
  expect.truthy(state.panel:pose(), 'the owner can still pose the panel')
  state.fixture:close()
end)

test('a panel arrival reaches the added listener with its options', function()
  local state = fixture.boot { width = 0.3, height = 0.2 }
  local uiHost = require '@lunette-contracts/ui-host'
  local arrived: { string } = {}
  local options: { uiHost.PanelOptions } = {}
  state.service:onPanelAdded(state.owner, {
    run = function(panel: uiHost.Panel, given: uiHost.PanelOptions)
      table.insert(arrived, panel.name)
      table.insert(options, given)
    end,
  })
  local made = state.service:newPanel(state.owner, { name = 'late', width = 0.2, height = 0.1 })
  expect.equal(arrived[1], 'late', 'the arrival is announced')
  expect.equal(options[1].width, 0.2, 'the creation options travel with it')
  local entries = state.service:panels()
  expect.equal(#entries, 2, 'the live top-level panels')
  local found = false
  for _, entry in entries do
    if entry.panel == made then
      found = true
    end
  end
  expect.truthy(found, 'the late panel is enumerated')
  made:destroy()
  state.fixture:close()
end)

return test
