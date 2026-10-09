local testing = require '@testing'
local surfaces = require '@lunette-contracts/surfaces'
local expect = testing.expect
local fixture = require './support/panel'
local test = testing.suite()

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
    { 'textField', { onChange = false } },
    { 'choice', { items = { [2] = { id = 'item', label = 'Item' } }, onChange = function() end } },
    { 'list', { items = { { id = 'item', label = 'Item' }, named = true } } },
    { 'region', { receiver = {} } },
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
  local cases = { { visible = 'yes' }, { unknown = true }, { width = math.huge } }
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

return test
