local testing = require '@testing'
local surfaces = require '@lunette-contracts/surfaces'
local expect = testing.expect
local fixture = require './support/panel'
local suite = testing.suite()

local function test(name, run)
  suite(name, function()
    local ok, failure = pcall(run)
    fixture.closeAll()
    if not ok then
      error(failure, 0)
    end
  end)
end

local function bounds()
  return { x = 10, y = 260, width = 370, height = 30 }
end

local function focusCount(state)
  local count = 0
  for _, registration in state.focus.service:inspect().registrations do
    if registration.kind == 'focus' and registration.live then
      count += 1
    end
  end
  return count
end

local function surfaceCount(state)
  local service = state.fixture.session:observe(surfaces.capability).service
  local count = 0
  for _, registration in service:inspect().registrations do
    if registration.live then
      count += 1
    end
  end
  return count
end

local function receiver()
  return {
    key = function()
      return false
    end,
    text = function()
      return false
    end,
  }
end

local function regionItem()
  return { id = 'node', label = 'Node', bounds = bounds(), route = { { x = 10, y = 260 }, { x = 30, y = 280 } } }
end

test('malformed control options fail before validators or focus registration', function()
  local state = fixture.boot()
  local calls = 0
  local cases = {
    { 'button', { onActivate = false } },
    { 'button', {
      onActivate = function()
        calls += 1
      end,
      unknown = true,
    } },
    { 'textField', { value = false } },
    { 'textField', { onChange = false } },
    { 'textField', { onSubmit = 'invalid' } },
    { 'textField', { onCancel = {} } },
    { 'textField', { validate = true } },
    { 'textField', { keymapSeat = {} } },
    { 'textField', { keymapSeat = { dead = true } } },
    { 'choice', { items = {}, onChange = false } },
    { 'choice', { items = { [2] = { id = 'item', label = 'Item' } }, onChange = function() end } },
    { 'list', { items = {}, onChange = true } },
    { 'list', { items = { { id = 'item', label = 'Item' }, named = true } } },
    { 'region', { wantsKeyboard = 'yes' } },
    { 'region', { onPointer = false } },
    { 'region', { receiver = {} } },
    { 'region', { receiver = {
      key = false,
      text = function()
        return true
      end,
    } } },
    { 'region', { receiver = {
      key = function()
        return true
      end,
      text = false,
    } } },
    {
      'region',
      {
        receiver = {
          key = function()
            return true
          end,
          text = function()
            return true
          end,
          onFocus = false,
        },
      },
    },
    {
      'region',
      {
        receiver = {
          key = function()
            return true
          end,
          text = function()
            return true
          end,
          unknown = true,
        },
      },
    },
    { 'region', { receiver = setmetatable(receiver(), {}) } },
    {
      'region',
      {
        receiver = {
          key = function()
            return false
          end,
          text = function()
            return false
          end,
          onBlur = false,
        },
      },
    },
  }
  for index, case in cases do
    local options = table.clone(case[2])
    options.id, options.bounds = 'invalid-' .. index, bounds()
    if case[1] == 'textField' and options.validate == nil then
      options.validate = function()
        calls += 1
        return nil
      end
    end
    local revision, targets = state.panel:describe().revision, focusCount(state)
    expect.falsy(
      pcall(function()
        state.panel[case[1]](state.panel, state.owner, options)
      end),
      case[1] .. ' rejects'
    )
    expect.equal(state.panel:describe().revision, revision, 'rejection leaves the description unchanged')
    expect.equal(focusCount(state), targets, 'rejection does not register focus')
    expect.equal(calls, 0, 'rejection does not execute callbacks')
  end
  local common = { label = false, enabled = 'yes', z = math.huge, draw = true, exclusive = 'yes' }
  for field, value in common do
    local options = {
      id = 'common-' .. field,
      bounds = bounds(),
      onActivate = function()
        calls += 1
      end,
    }
    options[field] = value
    expect.falsy(
      pcall(function()
        state.panel:button(state.owner, options)
      end),
      field .. ' rejects'
    )
  end
  expect.falsy(
    pcall(function()
      state.panel:region(state.owner, setmetatable({ id = 'nonplain', bounds = bounds() }, {}))
    end),
    'options are plain'
  )
end)

test('region item schemas reject sparse named and malformed geometry atomically', function()
  local state = fixture.boot()
  local region = state.region
  local cases = {
    { [2] = regionItem() },
    { regionItem(), named = regionItem() },
    setmetatable({ regionItem() }, {}),
    { setmetatable(regionItem(), {}) },
    { { id = 'node', bounds = bounds(), label = false } },
    { { id = 'node', bounds = bounds(), unknown = true } },
    { { id = 'node', bounds = bounds(), route = { [2] = { x = 10, y = 260 } } } },
    { { id = 'node', bounds = bounds(), route = { { x = 10, y = 260 }, named = true } } },
    { { id = 'node', bounds = bounds(), route = { { x = 10, y = 260, unknown = true } } } },
    { { id = 'node', bounds = bounds(), route = setmetatable({}, {}) } },
    { { id = 'node', bounds = { x = 0, y = 0, width = 10, height = 10, unknown = true } } },
    { { id = 'node', bounds = { x = math.huge, y = 0, width = 10, height = 10 } } },
    { regionItem(), regionItem() },
  }
  local before = state.panel:describe()
  for index, items in cases do
    expect.falsy(
      pcall(function()
        region:setItems(items)
      end),
      'invalid setter ' .. index
    )
    local current = state.panel:describe()
    expect.equal(current.revision, before.revision, 'a failed setter retains the revision')
    expect.equal(current.controls[#current.controls].items[1].label, 'Node', 'a failed setter retains items')
    expect.falsy(
      pcall(function()
        state.panel:region(state.owner, { id = 'invalid-region-' .. index, bounds = bounds(), items = items })
      end),
      'invalid construction ' .. index
    )
    expect.equal(state.panel:describe().revision, before.revision, 'failed construction is atomic')
  end
  state.field:setError 'Previous error'
  local revision = state.panel:describe().revision
  expect.falsy(
    pcall(function()
      state.field:setError(false)
    end),
    'setError rejects nonstrings'
  )
  expect.equal(state.panel:describe().revision, revision, 'an invalid error does not commit')
  expect.falsy(
    pcall(function()
      state.field:setValue(false)
    end),
    'setValue rejects nonstrings'
  )
  expect.equal(state.panel:describe().revision, revision, 'an invalid value does not commit')
end)

test('panel options reject malformed data without acquiring a surface', function()
  local state = fixture.boot()
  local cases = { { visible = 'yes' }, { grabbable = 1 }, { draw = false }, { unknown = true }, { width = math.huge } }
  local count, registrations = #state.service:panels(), surfaceCount(state)
  for index, bad in cases do
    local options = {
      name = 'invalid-panel-' .. index,
      width = 1,
      height = 1,
      logicalWidth = 100,
      logicalHeight = 100,
    }
    for field, value in bad do
      options[field] = value
    end
    expect.falsy(
      pcall(function()
        state.service:newPanel(state.owner, options)
      end),
      'panel options reject'
    )
    expect.equal(#state.service:panels(), count, 'no panel was acquired')
    expect.equal(surfaceCount(state), registrations, 'no surface registration was acquired')
  end
  expect.falsy(
    pcall(function()
      state.service:newPanel(state.owner, { name = 'missing-dimensions', width = 1, height = 1 })
    end),
    'logical dimensions are required'
  )
  expect.equal(surfaceCount(state), registrations, 'missing dimensions acquire no surface')
end)

test('retained widget callbacks and receiver functions are creation snapshots', function()
  local state = fixture.boot()
  state.region:destroy()
  local original, replacement = 0, 0
  local options = {
    id = 'snapshot',
    bounds = bounds(),
    onActivate = function()
      original += 1
    end,
  }
  state.panel:button(state.owner, options)
  options.onActivate = function()
    replacement += 1
  end
  state.fixture:clickControl(state.service, 'public-ui-form', 'snapshot')
  expect.equal(original, 1, 'the original activation remains installed')
  expect.equal(replacement, 0, 'caller mutation cannot replace an activation')
  state.field:destroy()
  local fieldOptions = {
    id = 'snapshot-field',
    bounds = { x = 110, y = 10, width = 270, height = 40 },
    validate = function()
      original += 1
      return nil
    end,
    onChange = function()
      original += 1
    end,
  }
  local field = state.panel:textField(state.owner, fieldOptions)
  fieldOptions.validate = function()
    replacement += 1
    return nil
  end
  fieldOptions.onChange = function()
    replacement += 1
  end
  field:setValue 'changed'
  expect.truthy(field:focus(), 'the field acquires local focus')
  lovr.textinput 'typed'
  expect.equal(replacement, 0, 'caller mutation cannot replace text callbacks')
  field:blur()
  local rawReceiver = receiver()
  rawReceiver.onFocus = function()
    original += 1
  end
  local regionOptions = {
    id = 'snapshot-region',
    bounds = bounds(),
    receiver = rawReceiver,
    onPointer = function(event)
      if event.kind == 'press' then
        original += 1
      end
    end,
  }
  state.panel:region(state.owner, regionOptions)
  rawReceiver.onFocus = function()
    replacement += 1
  end
  regionOptions.onPointer = function()
    replacement += 1
  end
  local previous = original
  fixture.press(state, 'snapshot-region')
  expect.equal(original, previous + 2, 'the original receiver and pointer callback remain installed')
  expect.equal(replacement, 0, 'caller mutation cannot replace region callbacks')
end)

for _, action in { 'destroy-region', 'destroy-panel', 'disable', 'hide', 'bounds' } do
  test('region focus ' .. action .. ' does not deliver a stale press', function()
    local state = fixture.boot()
    state.region:destroy()
    local region
    local events = {}
    local rawReceiver = receiver()
    rawReceiver.onFocus = function()
      if action == 'destroy-region' then
        region:destroy()
      elseif action == 'destroy-panel' then
        state.panel:destroy()
      elseif action == 'disable' then
        region:setEnabled(false)
      elseif action == 'hide' then
        state.panel:setVisible(false)
      else
        region:setBounds { x = 10, y = 250, width = 370, height = 30 }
      end
    end
    region = state.panel:region(state.owner, {
      id = 'reentrant',
      bounds = bounds(),
      receiver = rawReceiver,
      onPointer = function(event)
        events[#events + 1] = event.kind
      end,
    })
    local description, described = state.fixture:discover(state.service, 'public-ui-form', 'reentrant')
    state.fixture:aim(description, described.bounds.x + 5, described.bounds.y + 5)
    state.fixture:step()
    local haptics = state.fixture.native.events.haptics or 0
    state.fixture:button('right', 'trigger', true)
    state.fixture:step()
    local presses, cancellations = 0, 0
    for _, kind in events do
      if kind == 'press' then
        presses += 1
      elseif kind == 'cancel' then
        cancellations += 1
      end
    end
    expect.equal(presses, 0, 'focus invalidation suppresses the original press')
    expect.equal(cancellations, 1, 'the original capture is cancelled once')
    expect.equal(state.fixture.native.events.haptics or 0, haptics, 'no stale press haptic continues')
  end)
end

return suite
