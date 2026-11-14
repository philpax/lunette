-- Covers lua/lunette-plugins/ui/standard/private/settings.luau: the header control, its popup, and the shared value.

local testing = require '@testing'
local fixture = require '@testing/ui-host'
local uiHost = require '@lunette-contracts/ui-host'
local curvature = require '../private/curvature'
local expect = testing.expect
local test = testing.suite()

local function boot(): fixture.State
  return fixture.boot { standard = true, width = 0.6, height = 0.5 }
end

local function show(state: fixture.State, panelProps: { [string]: any }?, body: { [string]: any }?): ()
  local c = assert(state.components)
  local props = panelProps or {}
  fixture.show(
    state,
    c.Panel {
      title = 'Workspace',
      onClose = function() end,
      properties = props.properties,
      propertiesControl = props.propertiesControl,
      c.Body { key = 'body', c.Text { key = 'text', text = 'Content' } },
    }
  )
end

local function open(state: fixture.State): ()
  fixture.click(state, 'header/band/settings/gear')
  state.fixture:step()
end

-- The node's own surface, in metres, so an aim inside an overlay reaches the control rather than the opener.
local function nodeGeometry(node: any): any
  local bounds = node:panelBounds()
  return {
    pose = node:pose(),
    width = bounds.width,
    height = bounds.height,
    logicalWidth = bounds.width,
    logicalHeight = bounds.height,
    visible = true,
  }
end

local function drag(state: fixture.State, path: string, from: { number }, to: { number }): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local geometry = nodeGeometry(node)
  local function at(point: { number }): (number, number)
    return point[1] * geometry.width, point[2] * geometry.height
  end
  local runner = state.fixture
  runner:button('right', 'trigger', false)
  runner:aim(geometry, at(from))
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 4 do
    local t = step / 4
    runner:aim(geometry, at { from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t })
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
end

-- Presses the centre sign button of a dial and releases it.
local function pressCentre(state: fixture.State, path: string): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local geometry = nodeGeometry(node)
  local runner = state.fixture
  runner:button('right', 'trigger', false)
  runner:aim(geometry, geometry.width / 2, geometry.height / 2)
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  runner:button('right', 'trigger', false)
  runner:step()
end

local function propertyEvents(state: fixture.State): { number }
  local count: { number } = { 0 }
  state.service:onPropertiesChanged(state.owner, {
    run = function(_panel: uiHost.Panel)
      count[1] += 1
    end,
  })
  return count
end

test('the gear and quick unlocks render as icon buttons', function()
  local state = boot()
  show(state)
  local gear = assert(state.panel:find 'header/band/settings/gear')
  expect.equal(gear.props.label, 'Settings', 'the gear is named Settings')
  expect.truthy(gear.props.icon, 'the gear draws an icon')
  expect.falsy(gear.props.active, 'the menu starts closed')
  expect.equal(state.panel:find 'header/band/settings/input-lock', nil, 'an unlocked panel offers no quick lock')
  expect.equal(state.panel:find 'header/band/settings/transform-lock', nil, 'nor a transform lock')
  expect.equal(state.service:findByRole('button', 'Settings'), gear, 'the gear is reachable by role and name')
  expect.truthy(state.service:nextPanel(), 'the panel takes session focus')
  expect.truthy(state.service:navigate 'next', 'traversal reaches the controls')
  open(state)
  fixture.click(state, 'header/band/settings/popup/body/input-lock')
  state.fixture:step()
  fixture.click(state, 'header/band/settings/popup/body/transform-lock')
  state.fixture:step()
  local input = assert(state.panel:find 'header/band/settings/input-lock')
  expect.equal(input.props.label, 'Unlock input', 'the quick input lock names its action')
  expect.truthy(input.props.icon, 'the input lock draws an icon')
  expect.truthy(input.props.active, 'the quick input lock shows the locked state')
  local transform = assert(state.panel:find 'header/band/settings/transform-lock')
  expect.equal(transform.props.label, 'Unlock transform', 'the quick transform lock names its action')
  expect.truthy(transform.props.icon, 'the transform lock draws an icon')
  expect.equal(
    state.service:findByRole('button', 'Unlock input'),
    input,
    'the quick lock is reachable by role and name'
  )
  state.fixture:close()
end)

test('the Settings popup contains bend, axis, and both locks', function()
  local state = boot()
  show(state)
  expect.equal(state.panel:find 'header/band/settings/popup', nil, 'the menu is absent while closed')
  open(state)
  expect.truthy(state.panel:find 'header/band/settings/popup', 'the menu opens')
  local title = assert(state.panel:find 'header/band/settings/popup/body/title')
  expect.equal(title.props.text, 'Settings', 'the popup heading')
  expect.truthy(state.panel:find 'header/band/settings/popup/body/bend/heading/label', 'the bend row')
  expect.truthy(state.panel:find 'header/band/settings/popup/body/bend/track', 'the bend slider')
  expect.truthy(state.panel:find 'header/band/settings/popup/body/axis/heading/label', 'the axis row')
  expect.truthy(state.panel:find 'header/band/settings/popup/body/axis/track', 'the axis slider')
  expect.truthy(state.panel:find 'header/band/settings/popup/body/input-lock', 'the input lock toggle')
  expect.truthy(state.panel:find 'header/band/settings/popup/body/transform-lock', 'the transform lock toggle')
  fixture.click(state, 'body/text')
  expect.equal(state.panel:find 'header/band/settings/popup', nil, 'a press outside dismisses the menu')
  state.fixture:close()
end)

test('the quick locks and the Settings toggles share state', function()
  local state = boot()
  show(state)
  open(state)
  fixture.click(state, 'header/band/settings/popup/body/input-lock')
  state.fixture:step()
  expect.truthy(state.panel:locked(), 'the Settings toggle locks')
  local input = assert(state.panel:find 'header/band/settings/input-lock')
  expect.equal(input.props.label, 'Unlock input', 'the quick unlock appears while locked')
  expect.truthy(input.props.active, 'the quick unlock reads active')
  local toggle = assert(state.panel:find 'header/band/settings/popup/body/input-lock')
  expect.truthy(toggle.props.value, 'the Settings toggle shows the lock')
  fixture.click(state, 'header/band/settings/input-lock')
  state.fixture:step()
  expect.falsy(state.panel:locked(), 'the quick unlock unlocks')
  expect.equal(state.panel:find 'header/band/settings/input-lock', nil, 'the quick unlock disappears')
  toggle = assert(state.panel:find 'header/band/settings/popup/body/input-lock')
  expect.falsy(toggle.props.value, 'the Settings toggle follows the quick unlock')
  state.fixture:close()
end)

test('the bend slider bends the panel and commits once on release', function()
  local state = boot()
  show(state)
  local events = propertyEvents(state)
  open(state)
  drag(state, 'header/band/settings/popup/body/bend/track', { 0.15, 0.5 }, { 0.5, 0.15 })
  expect.truthy(state.panel:curve() > 0, 'the panel bends towards the viewer')
  expect.equal(events[1], 1, 'the release commits once')
  state.fixture:close()
end)

test('the axis slider turns the bend and keeps the arc', function()
  local state = boot()
  show(state)
  open(state)
  drag(state, 'header/band/settings/popup/body/bend/track', { 0.15, 0.5 }, { 0.5, 0.15 })
  local before = curvature.read {
    curve = state.panel:curve(),
    axis = state.panel:curveAxis(),
    width = select(1, state.panel:size()),
    height = select(2, state.panel:size()),
  }
  drag(state, 'header/band/settings/popup/body/axis/track', { 0.15, 0.5 }, { 0.5, 0.15 })
  expect.truthy(state.panel:curveAxis() ~= 0, 'the axis turns')
  local after = curvature.read {
    curve = state.panel:curve(),
    axis = state.panel:curveAxis(),
    width = select(1, state.panel:size()),
    height = select(2, state.panel:size()),
  }
  expect.near(after.bend, before.bend, 1.0, 'the arc is kept while the axis turns')
  state.fixture:close()
end)

local function keyboard(state: fixture.State): any
  local focusContract = require '@lunette-contracts/focus'
  local observed = assert(state.fixture.session):observe(focusContract.capability)
  local service = assert(observed.service)
  return service, service:newSource(assert(observed.context), { mode = 'virtual' })
end

local function enterBend(state: fixture.State, text: string): ()
  fixture.click(state, 'header/band/settings/popup/body/bend/heading/value')
  state.fixture:step()
  local _, source = keyboard(state)
  local codes = require('@lunette-contracts/keys').CODES
  for _ = 1, 12 do
    source:key { code = codes.backspace }
  end
  source:text(text)
  source:key { code = codes.enter }
  state.fixture:step()
end

test('a numeric entry sets the bend and an out-of-range entry is clamped on submit', function()
  local state = boot()
  show(state)
  open(state)
  enterBend(state, '22.5')
  local decimal = curvature.read {
    curve = state.panel:curve(),
    axis = state.panel:curveAxis(),
    width = select(1, state.panel:size()),
    height = select(2, state.panel:size()),
  }
  expect.near(decimal.bend, 22.5, 0.05, 'a decimal entry is kept')
  expect.equal(assert(state.panel:find 'header/band/settings/popup/body/bend/heading/value').props.value, '22.5')
  enterBend(state, '90')
  local width, height = state.panel:size()
  local shown =
    curvature.read { curve = state.panel:curve(), axis = state.panel:curveAxis(), width = width, height = height }
  expect.near(shown.bend, 90, 0.5, 'the entry bends the panel')
  enterBend(state, '1000')
  local clamped = curvature.read {
    curve = state.panel:curve(),
    axis = state.panel:curveAxis(),
    width = width,
    height = height,
  }
  expect.near(clamped.bend, curvature.MAX_BEND, 1.0, 'the out-of-range entry is clamped')
  state.fixture:close()
end)

test('closing the popup reverts an uncommitted preview', function()
  local state = boot()
  show(state)
  local events = propertyEvents(state)
  open(state)
  local track = assert(state.panel:find 'header/band/settings/popup/body/bend/track')
  track.props.onPreview(90)
  state.fixture:step()
  expect.truthy(state.panel:curve() > 0, 'the preview applies')
  expect.equal(events[1], 0, 'the preview does not commit')
  fixture.click(state, 'body/text')
  expect.equal(state.panel:curve(), 0, 'dismissing the menu reverts the preview')
  expect.equal(events[1], 0, 'the revert writes nothing')
  state.fixture:close()
end)

test('opening and closing an over-limit panel preserves the raw curve and axis', function()
  local state = boot()
  show(state)
  state.panel:setCurve(100, math.pi / 4, true)
  local events = propertyEvents(state)
  open(state)
  fixture.click(state, 'body/text')
  expect.equal(state.panel:curve(), 100, 'the raw curve is restored')
  expect.near(state.panel:curveAxis(), math.pi / 4, 1e-9, 'the raw axis is restored')
  expect.equal(events[1], 0, 'restoring writes nothing')
  state.fixture:close()
end)

test('committing the displayed bend lowers the stored curve to the limit', function()
  local state = boot()
  show(state)
  state.panel:setCurve(100, 0, true)
  open(state)
  local track = assert(state.panel:find 'header/band/settings/popup/body/bend/track')
  track.props.onFinish(track.props.value)
  state.fixture:step()
  local width, height = state.panel:size()
  expect.truthy(state.panel:curve() < 100, 'the commit lowers the stored curve')
  expect.near(
    state.panel:curve(),
    curvature.curve(track.props.value, 0, width, height),
    1e-9,
    'the stored curve is the displayed arc'
  )
  state.fixture:close()
end)

test('a controller without an axis disables the axis row and states its reason', function()
  local state = boot()
  local previews: { { number } } = {}
  local commits: { number } = {}
  local controller: any = {
    bend = function(): uiHost.Bend
      return { curve = 0.2, axis = 0, width = 0.6, height = 0.5 }
    end,
    setCurve = function(curve: number, axis: number, commit: boolean?)
      if commit then
        table.insert(commits, curve)
      else
        table.insert(previews, { curve, axis })
      end
    end,
    axis = false,
    negative = false,
    axisReason = 'Window and monitor panels bend about the vertical.',
    inputLock = {
      available = true,
      get = function(): boolean
        return false
      end,
      set = function() end,
    },
    transformLock = {
      available = true,
      get = function(): boolean
        return false
      end,
      set = function() end,
    },
  }
  show(state, { properties = controller })
  open(state)
  local bend = assert(state.panel:find 'header/band/settings/popup/body/bend/track')
  expect.equal(bend.props.min, 0, 'the bend starts at flat')
  local axis = assert(state.panel:find 'header/band/settings/popup/body/axis/track')
  expect.truthy(axis.props.disabled, 'the axis is disabled')
  expect.equal(axis.props.disabledReason, controller.axisReason, 'the axis states why')
  bend.props.onFinish(90)
  expect.equal(#commits, 1, 'the bend commits through the controller')
  state.fixture:close()
end)

test('a quick lock is hidden and its toggle disabled when the lock does not apply', function()
  local state = boot()
  local controller: any = {
    bend = function(): uiHost.Bend
      return { curve = 0, axis = 0, width = 0.6, height = 0.5 }
    end,
    setCurve = function() end,
    axis = true,
    negative = true,
    inputLock = {
      available = false,
      reason = 'This panel takes no content input.',
      get = function(): boolean
        return false
      end,
      set = function() end,
    },
    transformLock = {
      available = false,
      reason = 'This panel has no placement a grab can move.',
      get = function(): boolean
        return false
      end,
      set = function() end,
    },
  }
  show(state, { properties = controller })
  expect.equal(state.panel:find 'header/band/settings/input-lock', nil, 'the quick input lock is hidden')
  expect.equal(state.panel:find 'header/band/settings/transform-lock', nil, 'the quick transform lock is hidden')
  open(state)
  local input = assert(state.panel:find 'header/band/settings/popup/body/input-lock')
  expect.truthy(input.props.disabled, 'the input toggle is disabled')
  expect.equal(input.props.disabledReason, controller.inputLock.reason, 'the input toggle states why')
  local transform = assert(state.panel:find 'header/band/settings/popup/body/transform-lock')
  expect.truthy(transform.props.disabled, 'the transform toggle is disabled')
  expect.equal(transform.props.disabledReason, controller.transformLock.reason, 'the transform toggle states why')
  state.fixture:close()
end)

test('the Settings popup is parented to the panel and keeps its angle through a bend', function()
  local state = boot()
  show(state)
  open(state)
  local function popup(): (number, number, number, number, number, number)
    local title = assert(state.panel:find 'header/band/settings/popup/body/title')
    local pose = title:pose()
    local x, y, z = pose:getPosition()
    local fx, fy, fz = pose:mul(0, 0, 1, 0)
    return x, y, z, fx, fy, fz
  end
  local x, y, z, fx, fy, fz = popup()
  drag(state, 'header/band/settings/popup/body/bend/track', { 0.15, 0.5 }, { 0.5, 0.15 })
  expect.truthy(state.panel:curve() > 0, 'the bend changed')
  local bentX, bentY, bentZ, bentFx, bentFy, bentFz = popup()
  expect.near(bentX, x, 1e-6, 'the bend does not move the popup in x')
  expect.near(bentY, y, 1e-6, 'the bend does not move the popup in y')
  expect.near(bentZ, z, 1e-6, 'the bend does not move the popup in z')
  expect.near(bentFx, fx, 1e-6, 'the bend keeps the popup angle in x')
  expect.near(bentFy, fy, 1e-6, 'the bend keeps the popup angle in y')
  expect.near(bentFz, fz, 1e-6, 'the bend keeps the popup angle in z')
  local px, py, pz = state.panel:pose():getPosition()
  state.panel:setPose(lovr.math.newMat4():translate(px + 0.2, py, pz))
  state.fixture:step()
  expect.near(popup() - bentX, 0.2, 1e-5, 'moving the panel carries the popup along')
  state.fixture:close()
end)

test('a dial commit keeps its fractional snap angle', function()
  local state = boot()
  show(state)
  open(state)
  local angle = math.rad(22.5)
  local to = { 0.5 - 0.3 * math.cos(angle), 0.5 - 0.3 * math.sin(angle) }
  drag(state, 'header/band/settings/popup/body/bend/track', { 0.15, 0.5 }, to)
  local width, height = state.panel:size()
  local shown =
    curvature.read { curve = state.panel:curve(), axis = state.panel:curveAxis(), width = width, height = height }
  expect.near(shown.bend, 22.5, 0.1, 'the fractional snap is kept')
  state.fixture:close()
end)

test('the bend centre button bends away from the viewer', function()
  local state = boot()
  show(state)
  open(state)
  drag(state, 'header/band/settings/popup/body/bend/track', { 0.15, 0.5 }, { 0.5, 0.15 })
  local width, height = state.panel:size()
  local forward = curvature.read {
    curve = state.panel:curve(),
    axis = state.panel:curveAxis(),
    width = width,
    height = height,
  }
  expect.near(forward.bend, 90, 1.0, 'the bend is towards the viewer')
  pressCentre(state, 'header/band/settings/popup/body/bend/track')
  local away = curvature.read {
    curve = state.panel:curve(),
    axis = state.panel:curveAxis(),
    width = width,
    height = height,
  }
  expect.near(away.bend, -90, 1.0, 'the centre button bends away')
  state.fixture:close()
end)

test('the axis turns while the panel is flat', function()
  local state = boot()
  show(state)
  open(state)
  drag(state, 'header/band/settings/popup/body/axis/track', { 0.15, 0.5 }, { 0.5, 0.15 })
  expect.truthy(state.panel:curveAxis() ~= 0, 'the axis turns before a bend')
  local axis = assert(state.panel:find 'header/band/settings/popup/body/axis/heading/value')
  expect.truthy(axis.props.value ~= '0.0', 'the numeric entry follows the axis')
  state.fixture:close()
end)

return test
