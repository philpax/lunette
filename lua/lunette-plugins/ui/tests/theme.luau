local testing = require '@testing'
local theme = require '../theme'
local config = require '../config'
local expect = testing.expect
local test = testing.suite()

test('provider, panel, and control overrides resolve in order', function()
  local color = { 0.1, 0.2, 0.3, 1 }
  local provider = config.parse { theme = { fontSize = 22, foreground = color } }
  local providerSpec = theme.inherit(theme.DEFAULT, theme.project(provider.theme))
  local panel = theme.inherit(providerSpec, theme.copyOverrides { fontSize = 26, padding = 12 })
  local control =
    theme.materialize(theme.inherit(panel, theme.copyOverrides { padding = 0 }), require('@testing/render').new().font)
  expect.equal(control.fontSize, 26)
  expect.equal(control.padding, 0)
  expect.equal(control.foreground[1], 0.1)
  expect.equal(provider.theme.padding, nil)
  expect.equal(providerSpec.padding, theme.DEFAULT.padding)
end)

test('schema projections expose defaults and a callable passthrough hook', function()
  local settings = config.parse {}
  expect.equal(settings.theme.fontSize, nil)
  expect.equal(theme.inherit(theme.DEFAULT, theme.project(settings.theme)).fontSize, theme.DEFAULT.fontSize)
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
      theme.copyOverrides(overrides)
    end)
    expect.raises(function()
      config.parse { theme = overrides }
    end)
  end
  expect.raises(function()
    config.parse { typo = true }
  end)
end)

return test
