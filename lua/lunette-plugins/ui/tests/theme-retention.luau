local testing = require '@testing'
local theme = require '../theme'
local expect = testing.expect
local test = testing.suite()

test('copying overrides preserves nil and empty layers without filling defaults', function()
  expect.equal(theme.copyOverrides(nil), nil)
  local empty = {}
  local copied = theme.copyOverrides(empty)
  expect.truthy(copied ~= empty)
  expect.truthy(table.isfrozen(copied))
  expect.equal(next(copied), nil)
  local partial = theme.copyOverrides { fontSize = 24, foreground = nil }
  expect.equal(partial.fontSize, 24)
  expect.equal(partial.foreground, nil)
  expect.equal(partial.padding, nil)
  expect.equal(theme.resolve(theme.DEFAULT, partial).foreground[1], theme.DEFAULT.foreground[1])
end)

test('every retained color is detached and deeply frozen without freezing its input', function()
  local original = table.clone(theme.DEFAULT)
  for key, value in original do
    if type(value) == 'table' then
      original[key] = table.clone(value)
    end
  end
  local copied = theme.copyOverrides(original)
  expect.truthy(copied ~= original)
  expect.truthy(table.isfrozen(copied))
  expect.equal(table.isfrozen(original), false)
  for key, value in original do
    if type(value) == 'table' then
      local retained = copied[key]
      expect.truthy(retained ~= value, key .. ' owns its color array')
      expect.truthy(table.isfrozen(retained), key .. ' is immutable')
      expect.equal(table.isfrozen(value), false, key .. ' input stays mutable')
      local component = retained[1]
      value[1] = 0.7
      expect.equal(retained[1], component, key .. ' retains its original component')
      expect.raises(function()
        retained[1] = 0.6
      end)
    else
      expect.equal(copied[key], value, key .. ' is preserved')
    end
  end
  expect.raises(function()
    copied.padding = 1
  end)
end)

test('retained layers survive color mutation and preserve precedence across recomputation', function()
  local panelColor = { 0.1, 0.2, 0.3, 1 }
  local controlColor = { 0.4, 0.5, 0.6, 1 }
  local panelInput = { foreground = panelColor, padding = 12, fontSize = 26 }
  local controlInput = { foreground = controlColor, padding = 0 }
  local panelOverrides = theme.copyOverrides(panelInput)
  local controlOverrides = theme.copyOverrides(controlInput)
  local initialPanel = theme.resolve(theme.DEFAULT, panelOverrides)
  local initialControl = theme.resolve(initialPanel, controlOverrides)
  expect.equal(initialPanel.foreground[1], 0.1)
  expect.equal(initialControl.foreground[1], 0.4)
  panelColor[1] = 0.9
  controlColor[1] = 0.8
  panelInput.padding = 99
  controlInput.padding = 99
  local provider = theme.resolve(theme.DEFAULT, { foreground = { 0.7, 0.7, 0.7, 1 }, spacing = 11 })
  local panel = theme.resolve(provider, panelOverrides)
  local control = theme.resolve(panel, controlOverrides)
  expect.equal(panel.foreground[1], 0.1)
  expect.equal(panel.padding, 12)
  expect.equal(control.foreground[1], 0.4)
  expect.equal(control.padding, 0)
  expect.equal(control.fontSize, 26)
  expect.equal(control.spacing, 11)
  expect.equal(theme.resolve(provider, theme.copyOverrides(nil)).foreground[1], 0.7)
  expect.equal(theme.resolve(panel, theme.copyOverrides(nil)).foreground[1], 0.1)
end)

test('retained override schemas reject unknown fields and non-plain containers at every layer', function()
  for _, invalid in
    {
      { typo = 1 },
      { [1] = true },
      setmetatable({}, {}),
      { foreground = setmetatable({ 1, 1, 1, 1 }, {}) },
      { foreground = { 1, 1, 1, 1, extra = true } },
      { foreground = { [1] = 1, [2] = 1, [4] = 1, [5] = 1 } },
      { foreground = { 1, 1, 1 } },
      { foreground = { 1, 1, 1, 1, 1 } },
      { foreground = { 1, 1, 1, -0.1 } },
      { foreground = { 1, 1, 1, math.huge } },
      { foreground = { 1, 1, 1, 0 / 0 } },
      { fontSize = 0 },
      { rowHeight = -1 },
      { padding = -1 },
      { spacing = math.huge },
      { borderWidth = 0 / 0 },
      { hapticStrength = 1.1 },
      { hapticDuration = -1 },
    }
  do
    expect.raises(function()
      theme.copyOverrides(invalid)
    end, 'ui theme overrides:')
  end
  local recursive = {}
  recursive[1] = recursive
  expect.raises(function()
    theme.copyOverrides { foreground = recursive }
  end, 'ui theme overrides:')
end)

test('retained zero values remain explicit through inheritance', function()
  local copied = theme.copyOverrides {
    padding = 0,
    spacing = 0,
    borderWidth = 0,
    hapticStrength = 0,
    hapticDuration = 0,
  }
  local resolved = theme.resolve(theme.DEFAULT, copied)
  for key, value in copied do
    expect.equal(value, 0, key .. ' stays explicit')
    expect.equal(resolved[key], 0, key .. ' overrides its default')
  end
end)

return test
