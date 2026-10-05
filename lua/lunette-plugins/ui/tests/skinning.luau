local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/panel'
local test = testing.suite()

local function run(options, scenario)
  local state = fixture.boot(options)
  local ok, failure = pcall(scenario, state)
  fixture.closeAll()
  if not ok then
    error(failure, 0)
  end
end

test('UI theme and draw hook skinning preserves input', function()
  local heard = {}
  run({
    theme = { background = { 0.9, 0.1, 0.7, 1 }, foreground = { 0, 0, 0, 1 }, rowHeight = 35 },
    draw = function(pass, visual, base)
      heard[#heard + 1] = visual
      expect.truthy(table.isfrozen(visual), 'draw state is immutable')
      base(pass, visual)
      if visual.kind == 'button' then
        pass:setColor(0.1, 0.8, 0.2, 1)
        local bounds = visual.clip
        pass:plane(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0.001, bounds.width, bounds.height)
      end
    end,
  }, function(state)
    local before = state.panel:describe()
    state.fixture:clickControl(state.service, 'public-ui-form', 'run')
    expect.equal(#state.activations, 1, 'custom rendering preserves real enabled-control input')
    state.fixture:draw()
    local after = state.panel:describe()
    expect.equal(before.controls[1].bounds.x, after.controls[1].bounds.x, 'drawing does not move input')
    local button
    for _, visual in ipairs(heard) do
      if visual.id == 'run' then
        button = visual
      end
    end
    expect.truthy(button, 'panel hook receives control visual state')
    expect.equal(button.theme.background[1], 0.9, 'altered panel colour reaches rendering')
    expect.equal(button.theme.rowHeight, 35, 'geometry style reaches controls')
    local colour = false
    for _, call in ipairs(state.fixture:drawCalls 'setColor') do
      if call[2] == 0.1 and call[3] == 0.8 and call[4] == 0.2 then
        colour = true
      end
    end
    expect.truthy(colour, 'the recorder sees custom visual output')
    state.field:focus()
    fixture.press(state, 'run')
    state.fixture:draw()
    local pressed, focused = false, false
    for _, visual in ipairs(heard) do
      pressed = pressed or (visual.id == 'run' and visual.pressed)
      focused = focused or (visual.id == 'draft' and visual.focused)
    end
    expect.truthy(pressed, 'hooks see actual pressed state')
    expect.truthy(focused, 'hooks see routed field focus')
    state.button:setEnabled(false)
    state.fixture:draw()
    expect.equal(#state.activations, 1, 'disable cancels the held gesture under the custom skin')
  end)
end)

test('widgets custom draw restores pass', function()
  run({
    draw = function(pass, visual, base)
      base(pass, visual)
      if visual.id == 'run' then
        pass:translate(100, 100, 100)
        pass:setColor(0, 0, 0, 0)
        error 'custom UI draw failure'
      end
    end,
  }, function(state)
    local recorder = state.fixture.native.events.render
    local pass = recorder.pass
    local checkpoint = recorder:checkpoint()
    expect.raises(function()
      state.panel:draw(pass)
    end, 'custom UI draw failure', 'drawing error is not swallowed')
    recorder:assertRestored(checkpoint)
    local calls = #recorder.calls
    pass:plane(0, 0, 0, 1, 1)
    expect.near(recorder.calls[calls + 1].points[1].x, -0.5, 0.0001, 'panel transform is restored')
  end)
end)

return test
