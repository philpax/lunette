local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local vrUi = require '@testing/vr-ui'
local test = testing.suite()

local function withPanel(run)
  local running = vrUi.boot {
    'theme',
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'laser',
    'keyboard',
    'desktop/pointing',
    'ui',
  }
  local state = { fixture = running, events = {} }
  local ok, failure = pcall(function()
    state.instance = running.session:use(plugin.define {
      name = 'testing/provider-lifecycle',
      requires = { ui = ui.capability },
      init = function(context)
        state.owner = context
        state.service = context:require(ui.capability)
        state.panel = state.service:newPanel(context, {
          name = 'provider-lifecycle',
          pose = lovr.math.newMat4():translate(0, 1.5, -2),
          width = 2,
          height = 1,
          logicalWidth = 400,
          logicalHeight = 200,
        })
      end,
    })
    run(state)
  end)
  local closed, cleanup = pcall(function()
    running:close()
  end)
  if not ok then
    error(tostring(failure) .. (if closed then '' else '\ncleanup: ' .. tostring(cleanup)), 0)
  end
  if not closed then
    error(cleanup, 0)
  end
end

local function region(state, owner, id, x, options)
  options = options or {}
  options.id = id
  options.bounds = { x = x, y = 20, width = 120, height = 100 }
  local callback = options.onPointer
  options.onPointer = function(event)
    state.events[#state.events + 1] = { id = id, event = event }
    if callback then
      callback(event)
    end
  end
  return state.panel:region(owner, options)
end

local function press(state, id, hand)
  local description, control = state.fixture:discover(state.service, 'provider-lifecycle', id)
  local bounds = assert(control.bounds)
  state.fixture:button(hand, 'trigger', false)
  state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, hand)
  state.fixture:step()
  state.beforePressHaptics = state.fixture.native.events.haptics or 0
  state.fixture:button(hand, 'trigger', true)
  state.fixture:step()
end

local function count(state, id, kind)
  local result = 0
  for _, recorded in ipairs(state.events) do
    if recorded.id == id and recorded.event.kind == kind then
      result += 1
    end
  end
  return result
end

local function release(state)
  state.fixture:step()
  state.fixture:button('left', 'trigger', false)
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
end

test('captured region owner teardown never invokes its ended owner', function()
  withPanel(function(state)
    local owner, control
    local instance = state.fixture.session:use(plugin.define {
      name = 'testing/provider-region-owner',
      requires = { ui = ui.capability },
      init = function(context)
        owner = context
        control = region(state, context, 'first', 20)
      end,
    })
    press(state, 'first', 'right')
    local before = #state.events
    instance:disable()
    expect.falsy(owner:active(), 'the region owner ended')
    expect.truthy(control.dead, 'owner teardown invalidates its region')
    expect.falsy(state.panel.dead, 'the other owner retains its panel')
    expect.equal(#state.events, before, 'an ended owner receives no terminal callback')
    release(state)
    expect.equal(count(state, 'first', 'release'), 0, 'the ended owner receives no stale release')
  end)
end)

return test
