local testing = require '@testing'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local fixture = require './support/panel'
local test = testing.suite()

type Bounds = fixture.Bounds
type InvalidPanelOptions = {
  name: string,
  width: number,
  height: number,
  logicalWidth: number | boolean,
  logicalHeight: number,
  visible: string?,
  unknown: boolean?,
}

local function bounds(): Bounds
  return { x = 10, y = 260, width = 370, height = 30 }
end

local function liveSurfaces(state: fixture.State): number
  local count = 0
  for _, registration in state.fixture.session:observe(surfaces.capability).service:inspect().registrations do
    if registration.live then
      count += 1
    end
  end
  return count
end

test('malformed options reject without changing the panel', function()
  local state = fixture.boot()
  local revision = vrUi.describe(state.service, 'public-ui-form').revision
  for _, case in
    {
      { 'button', { onActivate = false } },
      { 'button', { onActivate = function() end, unknown = true } },
      { 'button', { id = 'draft', onActivate = function() end } },
      { 'choice', { items = { [2] = { id = 'item', label = 'Item' } }, onChange = function() end } },
      { 'region', { items = { { id = 'node', bounds = bounds() }, { id = 'node', bounds = bounds() } } } },
    }
  do
    local options = table.clone(case[2])
    options.id = options.id or 'invalid'
    options.bounds = bounds()
    expect.falsy(pcall(state.panel[case[1]], state.panel, options), case[1] .. ' rejects')
  end
  expect.raises(function()
    state.region:setItems { { id = 'node', bounds = { x = math.huge, y = 0, width = 1, height = 1 } } }
  end)
  expect.raises(function()
    state.field:setValue(false :: any)
  end)
  local current = vrUi.describe(state.service, 'public-ui-form')
  expect.equal(current.revision, revision, 'rejections commit nothing')
  expect.equal(current.controls[#current.controls].items[1].label, 'Node', 'the region keeps its items')
end)

test('malformed panel options acquire no surface', function()
  local state = fixture.boot()
  local count = liveSurfaces(state)
  for _, change in { { 'visible', 'yes' }, { 'unknown', true }, { 'logicalWidth', false } } do
    local options: InvalidPanelOptions =
      { name = 'invalid', width = 1, height = 1, logicalWidth = 100, logicalHeight = 100 }
    options[change[1]] = change[2] or nil
    expect.falsy(pcall(state.service.newPanel, state.service, state.owner, options))
  end
  expect.equal(liveSurfaces(state), count)
end)

return test
