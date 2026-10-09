local testing = require '@testing'
local theme = require '../theme'
local config = require '../config'
local expect = testing.expect
local test = testing.suite()

test('provider, panel, and control overrides resolve in order', function()
  local color = { 0.1, 0.2, 0.3, 1 }
  local provider = config.schema.parse { theme = { fontSize = 22, foreground = color } }
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

test('theme schemas reject unknown, non-plain, and invalid values', function()
  for _, overrides in
    {
      { typo = 1 },
      { foreground = { 1, 1, 1, -0.1 } },
    }
  do
    expect.raises(function()
      theme.copyOverrides(overrides)
    end)
    expect.raises(function()
      config.schema.parse { theme = overrides }
    end)
  end
  expect.raises(function()
    config.schema.parse { typo = true }
  end)
end)

return test
