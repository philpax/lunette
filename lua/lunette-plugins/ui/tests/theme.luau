local testing = require '@testing'
local themes = require '../theme'
local theme = table.clone(themes)
theme.DEFAULT = themes.materialize(themes.DEFAULT, require('@testing/render').new().font)
local config = require '../config'
local expect = testing.expect
local test = testing.suite()

test('provider, panel, and control overrides resolve in order without aliasing', function()
  local color = { 0.1, 0.2, 0.3, 1 }
  local provider = config.parse { theme = { fontSize = 22, foreground = color } }
  local resolvedProvider = theme.resolve(theme.DEFAULT, themes.project(provider.theme))
  local panel = theme.resolve(resolvedProvider, { fontSize = 26, padding = 12 })
  local control = theme.resolve(panel, { padding = 0 })
  expect.equal(control.fontSize, 26)
  expect.equal(control.padding, 0)
  expect.equal(provider.theme.padding, nil)
  expect.equal(resolvedProvider.padding, theme.DEFAULT.padding)
  color[1] = 0.9
  expect.equal(provider.theme.foreground[1], 0.1)
  expect.truthy(table.isfrozen(control))
  expect.truthy(table.isfrozen(control.foreground))
  expect.truthy(control.foreground ~= panel.foreground)
end)

test('schema projections expose defaults and a callable passthrough hook', function()
  local settings = config.parse {}
  expect.equal(settings.theme.fontSize, nil)
  expect.equal(theme.resolve(theme.DEFAULT, themes.project(settings.theme)).fontSize, theme.DEFAULT.fontSize)
  local called = 0
  settings.draw({}, {}, function()
    called += 1
  end)
  expect.equal(called, 1)
  expect.truthy(config.inspect().fields.theme)
  expect.truthy(config.inspect().fields.draw)
end)

test('theme schemas reject unknown, non-plain, and invalid values', function()
  for _, overrides in
    {
      { typo = 1 },
      { fontSize = 0 },
      { rowHeight = -1 },
      { padding = -1 },
      { spacing = math.huge },
      { borderWidth = 0 / 0 },
      { hapticStrength = 1.1 },
      { hapticDuration = -1 },
      { foreground = { 1, 1, 1 } },
      { foreground = { 1, 1, 1, 1, 1 } },
      { foreground = { 1, 1, 1, -0.1 } },
      { foreground = { 1, 1, 1, math.huge } },
      setmetatable({}, { __index = { fontSize = 22 } }),
    }
  do
    expect.raises(function()
      theme.resolve(theme.DEFAULT, overrides)
    end)
    expect.raises(function()
      config.parse { theme = overrides }
    end)
  end
  expect.raises(function()
    config.parse { typo = true }
  end)
  local incomplete = table.clone(theme.DEFAULT)
  incomplete.foreground = nil
  expect.raises(function()
    theme.validate(incomplete)
  end, 'missing foreground')
end)

return test
