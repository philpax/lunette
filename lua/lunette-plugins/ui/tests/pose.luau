local testing = require '@testing'
local substitute = require '@testing/ui-substitute'
local fixture = require './support/panel'
local expect = testing.expect
local test = testing.suite()

for _, provider in
  {
    { name = 'built-in', definition = 'ui' },
    { name = 'substitute', definition = { id = 'ui', definition = substitute.definition } },
  }
do
  test(provider.name .. ' rigid panel motion preserves a held pointer capture', function()
    local state = fixture.boot { provider = provider.definition }
    local ok, failure = pcall(function()
      state.themes:select(state.owner, { radii = { uiPanel = 0.008 } })
      fixture.press(state, 'custom')
      local before = state.panel:describe()
      local pose
      for index = 1, 12 do
        pose = lovr.math
          .newMat4()
          :translate(0.2, 1.5, -2)
          :rotate(index * 0.17, 0.3, 0.8, 0.5)
          :rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
        state.panel:setPose(pose)
        state.panel:describe()
      end
      local after = state.panel:describe()
      expect.truthy(after.revision > before.revision, 'the moved geometry has a new revision')
      for _, event in state.events do
        expect.falsy(event.kind == 'cancel', 'rigid movement does not cancel a capture')
      end
      local _, control = state.fixture:discover(state.service, 'public-ui-form', 'custom')
      local bounds = control.bounds
      state.fixture:aim(after, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
      state.fixture:step()
      state.fixture:button('right', 'trigger', false)
      state.fixture:step()
      local releases = 0
      for _, event in state.events do
        if event.kind == 'release' then
          releases += 1
          expect.truthy(event.captured, 'the original gesture remains captured')
          expect.truthy(event.inside, 'release uses the moved panel hit geometry')
        end
      end
      expect.equal(releases, 1, 'one original gesture releases after motion')
      fixture.press(state, 'run')
      state.panel:setPose(lovr.math.newMat4(pose):translate(0.2, 0, 0):rotate(0.41, 0.2, 0.9, 0.3))
      local moved, button = state.fixture:discover(state.service, 'public-ui-form', 'run')
      local buttonBounds = button.bounds
      state.fixture:aim(moved, buttonBounds.x + buttonBounds.width / 2, buttonBounds.y + buttonBounds.height / 2)
      state.fixture:step()
      state.fixture:button('right', 'trigger', false)
      state.fixture:step()
      expect.equal(#state.activations, 1, 'an original button capture remains eligible after rigid motion')
      state.fixture:clickControl(state.service, 'public-ui-form', 'run')
      expect.equal(#state.activations, 2, 'new interaction uses the moved geometry')
    end)
    state.fixture:close()
    if not ok then
      error(failure, 0)
    end
  end)
end

return test
