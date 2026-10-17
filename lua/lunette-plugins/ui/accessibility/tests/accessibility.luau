local testing = require '@testing'
local accessibility = require '@lunette-contracts/accessibility'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

test('the configured settings start the store, and an invalid change is refused', function()
  local state = fixture.boot {
    standard = true,
    plugins = {
      {
        definition = require('@lunette-plugins/ui/accessibility').definition,
        config = { textScale = 1.5, sounds = false },
      },
    },
  }
  local service = assert(assert(state.fixture.session):observe(accessibility.capability).service)
  expect.equal(service.settings:get().textScale, 1.5, 'the configured text scale')
  expect.equal(service.settings:get().sounds, false, 'and sounds')
  expect.equal(service.settings:get().haptics, true, 'an unconfigured setting takes its default')
  expect.raises(function()
    service:update { textScale = 9 }
  end, 'not a valid textScale')
  expect.raises(function()
    service:update { colour = 'blue' }
  end, 'not a valid colour')
  expect.equal(service.settings:get().textScale, 1.5, 'a refused change leaves the settings')
  state.fixture:close()
end)

test('a change reaches the host, which applies text scale and high contrast', function()
  local state = fixture.boot {
    standard = true,
    plugins = { require('@lunette-plugins/ui/accessibility').definition },
  }
  local observed = assert(state.fixture.session):observe(accessibility.capability)
  local service = assert(observed.service)
  local before = state.service:theme().type.body.size
  service:update { textScale = 1.5, highContrast = true }
  expect.near(state.service:theme().type.body.size, before * 1.5, 1e-9, 'the host scales its type')
  expect.raises(function()
    service:update { textScale = 7 }
  end, 'not a valid textScale')
  state.fixture:close()
end)

test('the wrist menu action opens the settings panel, whose toggles change the settings', function()
  local menu = require '@lunette-contracts/menu'
  local state = fixture.boot {
    standard = true,
    plugins = {
      require('@lunette-plugins/menu/action-registry').definition,
      require('@lunette-plugins/ui/accessibility').definition,
      require('@lunette-plugins/ui/accessibility-settings').definition,
    },
  }
  local session = assert(state.fixture.session)
  local menus = assert(session:observe(menu.capability).service)
  local service = assert(session:observe(accessibility.capability).service)
  expect.equal(menus:invoke('desktop/accessibility').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  local toggle = assert(state.service:find 'Accessibility:body/display/content/highContrast/row', 'the panel is open')
  state.fixture:click(fixture.nodeGeometry(toggle), 0.5, 0.5)
  expect.equal(service.settings:get().highContrast, true, 'the toggle changed the setting')
  expect.equal(menus:invoke('desktop/accessibility').kind, 'invoked')
  state.fixture:step()
  expect.equal(state.service:find 'Accessibility:body', nil, 'the action closes the open panel')
  state.fixture:close()
end)

test('dragging the text size slider in the panel scales the theme', function()
  local menu = require '@lunette-contracts/menu'
  local state = fixture.boot {
    standard = true,
    plugins = {
      require('@lunette-plugins/menu/action-registry').definition,
      require('@lunette-plugins/ui/accessibility').definition,
      require('@lunette-plugins/ui/accessibility-settings').definition,
    },
  }
  local session = assert(state.fixture.session)
  local menus = assert(session:observe(menu.capability).service)
  local service = assert(session:observe(accessibility.capability).service)
  local before = state.service:theme().type.body.size
  expect.equal(menus:invoke('desktop/accessibility').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  local track = assert(state.service:find 'Accessibility:body/display/content/textScale/track', 'the panel is open')
  -- The geometry is a metre wide around the track's centre, so offsets from 0.5 are metres along the track.
  local geometry = fixture.nodeGeometry(track)
  local half = track.bounds.width / 2
  local runner = state.fixture
  runner:aim(geometry, 0.5 - half * 0.95, 0.5)
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 6 do
    runner:aim(geometry, 0.5 - half * 0.95 + half * 1.9 * step / 6, 0.5)
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
  runner:step()
  expect.near(service.settings:get().textScale, 2, 0.05, 'the slider commits the largest size')
  expect.near(state.service:theme().type.body.size, before * service.settings:get().textScale, 1e-9, 'the theme scales')
  state.fixture:close()
end)

test('the settings panel opens ahead of the head and moves with a trigger drag on its header', function()
  local menu = require '@lunette-contracts/menu'
  local state = fixture.boot {
    standard = true,
    plugins = {
      require('@lunette-plugins/menu/action-registry').definition,
      require('@lunette-plugins/ui/accessibility').definition,
      require('@lunette-plugins/ui/accessibility-settings').definition,
    },
  }
  local session = assert(state.fixture.session)
  local menus = assert(session:observe(menu.capability).service)
  state.fixture:pose('head', lovr.math.newMat4():translate(0.5, 1.6, 0))
  expect.equal(menus:invoke('desktop/accessibility').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  local spacer = assert(state.service:find 'Accessibility:header/band/spacer', 'the panel has the standard header')
  local opened = vector.pack(spacer:pose():getPosition())
  expect.near(opened.x, 0.5, 0.05, 'the panel opens ahead of the head')
  expect.truthy(opened.z < -0.4, 'in front of it')
  local geometry = fixture.nodeGeometry(spacer)
  local runner = state.fixture
  runner:aim(geometry, 0.5, 0.5)
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 4 do
    runner:aim(geometry, 0.5 + 0.2 * step / 4, 0.5)
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
  local moved = vector.pack(assert(state.service:find 'Accessibility:header/band/spacer'):pose():getPosition())
  expect.near(vector.magnitude(moved - opened), 0.2, 0.02, 'the header drag moves the panel')
  runner:step()
  local settled = vector.pack(assert(state.service:find 'Accessibility:header/band/spacer'):pose():getPosition())
  expect.near(vector.magnitude(settled - moved), 0, 1e-6, 'and it stays where it was left')
  state.fixture:close()
end)

test('the default appearance action switches the host, and its selection follows the host', function()
  local menu = require '@lunette-contracts/menu'
  local state = fixture.boot {
    standard = true,
    plugins = {
      require('@lunette-plugins/menu/action-registry').definition,
      require('@lunette-plugins/ui/accessibility').definition,
      require('@lunette-plugins/ui/accessibility-settings').definition,
    },
  }
  local session = assert(state.fixture.session)
  local menus = assert(session:observe(menu.capability).service)
  local function selected(): boolean?
    for _, entry in menus:list() do
      if entry.id == 'desktop/default-appearance' then
        return entry.selected
      end
    end
    return nil
  end
  expect.equal(selected(), false, 'the action starts unselected')
  expect.equal(menus:invoke('desktop/default-appearance').kind, 'invoked')
  expect.truthy(state.service:defaultAppearance(), 'the action switches default appearance on')
  state.fixture:step()
  expect.equal(selected(), true, 'the action shows default appearance as on')
  state.service:setDefaultAppearance(false)
  state.fixture:step()
  expect.equal(selected(), false, 'a change from elsewhere, such as the chord, reaches the action')
  state.fixture:close()
end)

return test
