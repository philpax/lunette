local testing = require '@testing'
local expect = testing.expect
local substitute = require '@testing/ui-substitute'
local fixture = require './support/panel'
local test = testing.suite()

local function scenario(provider)
  local state = fixture.boot { provider = provider, keyboard = true }
  local ok, failure = pcall(function()
    local first = state.panel:describe()
    state.fixture:clickControl(state.service, 'public-ui-form', 'run')
    expect.equal(#state.activations, 1, 'unchanged button consumer works')
    state.fixture:clickControl(state.service, 'public-ui-form', 'draft')
    fixture.key(state, 5)
    expect.equal(state.field:value(), 'é👩🏽‍💻', 'unchanged field consumer receives shared keyboard text')
    fixture.key(state, 2)
    expect.equal(state.field:value(), 'é', 'field edits one grapheme')
    state.fixture:clickControl(state.service, 'public-ui-form', 'run')
    expect.truthy(state.focus.service:focused(), 'nontext controls preserve editing')
    state.fixture:clickControl(state.service, 'public-ui-form', 'list', nil, 'item-1')
    expect.equal(state.listed, 'item-1', 'unchanged list consumer works')
    fixture.scroll(state, 'list', -1)
    local _, described = state.fixture:discover(state.service, 'public-ui-form', 'list')
    expect.truthy(described.items[1].id ~= 'item-1', 'substitute provides current clipped geometry')
    state.fixture:clickControl(state.service, 'public-ui-form', 'list', nil, described.items[#described.items].id)
    state.fixture:draw()
    expect.truthy(#state.fixture:drawCalls 'plane' > 0, 'consumer draws provider geometry')
    fixture.press(state, 'run')
    local panel, field, button = state.panel, state.field, state.button
    local eventCount = #state.events
    state.fixture.session.instances.ui:disable()
    expect.truthy(panel.dead and field.dead and button.dead, 'provider withdrawal invalidates retained handles')
    expect.equal(state.focus.service:focused(), nil, 'withdrawal clears local routing')
    expect.equal(#state.events, eventCount, 'withdrawal never invokes a callback belonging to an ended consumer')
    state.fixture.session.instances.ui:enable()
    expect.truthy(first.generation ~= state.panel:describe().generation, 'recovery changes public generation')
    state.fixture:step()
    expect.equal(#state.activations, 2, 'the held trigger cannot activate a replacement control')
    state.fixture:button('right', 'trigger', false)
    state.fixture:step()
    state.fixture:clickControl(state.service, 'public-ui-form', 'run')
    expect.equal(#state.activations, 3, 'same consumer reconnects after replacement')
  end)
  fixture.closeAll()
  if not ok then
    error(failure, 0)
  end
end

test('UI provider substitution runs unchanged consumers', function()
  scenario 'ui'
  scenario { id = 'ui', definition = substitute.definition }
end)

return test
