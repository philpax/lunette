local testing = require '@testing'
local expect = testing.expect
local surfaces = require '@lunette-contracts/surfaces'
local fixture = require './support/panel'
local test = testing.suite()

test('a UI panel offers a live surface with matching world hit geometry', function()
  local state = fixture.boot()
  local ok, failure = pcall(function()
    local observed = state.fixture.session:observe(surfaces.capability)
    local all = observed.service:all()
    expect.equal(#all, 1, 'one panel surface is offered')
    local offered = all[1]
    expect.falsy(offered.dead, 'the visible offered surface is live')
    expect.truthy(offered.onPointer, 'pointer handler is offered')
    local description, control = state.fixture:discover(state.service, 'public-ui-form', 'run')
    local bounds = control.bounds
    state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
    local hand = state.fixture.native.events.controllers.right
    local x, y, distance = offered:raycast(hand.origin, hand.direction)
    expect.near(x, 50, 0.001, 'public geometry and raycast x agree')
    expect.near(y, 30, 0.001, 'public geometry and raycast y agree')
    expect.near(distance, 1, 0.001, 'the ray reaches the panel')
    state.fixture:clickControl(state.service, 'public-ui-form', 'run')
    expect.equal(#state.activations, 1, 'actual pointer activates the offered button')
  end)
  state.fixture:close()
  if not ok then
    error(failure, 0)
  end
end)

local function releaseBeyondReach(state)
  local hand = state.fixture.native.events.controllers.right
  state.fixture:pose('right', lovr.math.newMat4(hand.pose):translate(0, 0, 100))
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
end

test('collection gestures released beyond reach do not activate from projected coordinates', function()
  local state = fixture.boot()
  local ok, failure = pcall(function()
    fixture.press(state, 'list', 'right', 'item-1')
    releaseBeyondReach(state)
    expect.equal(state.list:selected(), nil, 'a distant list release does not select')
    fixture.press(state, 'choice')
    releaseBeyondReach(state)
    local function choiceIsOpen()
      for _, control in state.panel:describe().controls do
        if control.id == 'choice' then
          return #control.items > 0
        end
      end
      return false
    end
    expect.falsy(choiceIsOpen(), 'a distant header release does not open')
    state.fixture:clickControl(state.service, 'public-ui-form', 'choice')
    expect.truthy(choiceIsOpen(), 'a new eligible header click opens')
    fixture.press(state, 'choice', 'right', 'item-1')
    releaseBeyondReach(state)
    expect.equal(state.choice:selected(), nil, 'a distant option release does not select')
    expect.truthy(choiceIsOpen(), 'a distant option release retains the open draft')
    state.fixture:clickControl(state.service, 'public-ui-form', 'choice', 'right', 'item-1')
    expect.equal(state.choice:selected(), 'item-1', 'a new eligible option click selects')
  end)
  state.fixture:close()
  if not ok then
    error(failure, 0)
  end
end)

return test
