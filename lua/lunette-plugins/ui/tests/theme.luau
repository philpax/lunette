local testing = require '@testing'
local theme = require '../theme'
local config = require '../config'
local titlebarConfiguration = require '../titlebar-configuration'
local stableTheme = require '@lunette-contracts/schemas/theme'
local frameStyle = require '@lunette-contracts/schemas/frame-style'
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

  for _, font in
    { {}, { kind = 'file', file = 'fonts/ui.ttf' }, { kind = 'file', file = 'fonts/ui.ttf', size = 48, spread = 6 } }
  do
    local settings = config.schema.parse { theme = { font = font }, titlebarStyle = { font = font } }
    local appearance = theme.project(settings.theme)
    local titlebar = titlebarConfiguration.project(settings.titlebarStyle)
    for _, projected in { appearance, titlebar } do
      expect.equal(projected.font.kind, font.kind or 'default')
      expect.equal(projected.font.file, font.file)
      expect.equal(projected.font.size, if font.kind == 'file' then font.size or 32 else nil)
      expect.equal(projected.font.spread, if font.kind == 'file' then font.spread or 4 else nil)
    end
    expect.equal(appearance.padding, nil, 'appearance projection stays sparse')
    expect.equal(titlebar.barHeight, nil, 'titlebar projection stays sparse')
    expect.equal(settings.theme.font.size, font.size, 'projection leaves the editable font unchanged')
  end
  local empty = config.schema.parse {}
  expect.equal(next(theme.project(empty.theme)), nil, 'an empty appearance has no defaults')
  expect.equal(next(titlebarConfiguration.project(empty.titlebarStyle)), nil, 'an empty titlebar has no defaults')

  local frame = {
    headerHeight = 0.1,
    headerRadius = 0.02,
    borderThickness = 0.01,
    borderDepth = 0.005,
    borderColor = color,
  }
  local detached = frameStyle.validate(frame)
  expect.truthy(detached.borderColor ~= color, 'frame validation detaches the color')
  expect.truthy(frameStyle.equal(frame, detached), 'equal frame colors compare by value')
  frame.borderColor[1] = 0.9
  expect.equal(detached.borderColor[1], 0.1, 'the detached color remains unchanged')
  expect.falsy(frameStyle.equal(frame, detached), 'a changed color changes the frame appearance')
end)

test('theme schemas reject unknown, non-plain, and invalid values', function()
  for _, overrides in
    {
      { typo = 1 },
      setmetatable({}, {}),
      { colors = { foreground = { 1, 1, 1, -0.1 } } },
      { typography = { font = { kind = 'default', file = 'fonts/ui.ttf' } } },
      { typography = { font = { kind = 'file', file = 'fonts/ui.ttf' } } },
    }
  do
    expect.raises(function()
      stableTheme.overrides.parse(overrides, 'theme overrides')
    end, 'theme overrides')
  end
  for _, overrides in
    {
      { typo = 1 },
      { foreground = { 1, 1, 1, -0.1 } },
      setmetatable({}, {}),
      { font = { kind = 'default', file = 'fonts/ui.ttf' } },
      { font = { kind = 'default', size = 32 } },
      { font = { kind = 'default', spread = 4 } },
      { font = { kind = 'file' } },
      { font = { kind = 'file', file = '' } },
      { font = { kind = 'file', file = 'fonts/ui.ttf', size = 0 } },
      { font = { kind = 'file', file = 'fonts/ui.ttf', spread = math.huge } },
      { font = { kind = 'file', file = 'fonts/ui.ttf', typo = true } },
    }
  do
    expect.raises(function()
      theme.copyOverrides(overrides)
    end)
    expect.raises(function()
      config.schema.parse { theme = overrides }
    end)
  end
  for _, overrides in
    {
      { typo = 1 },
      setmetatable({}, {}),
      { titleColor = { 1, 1, 1, -0.1 } },
      { barHeight = 0 },
      { cornerRadius = -1 },
      { font = { kind = 'default', file = 'fonts/ui.ttf' } },
      { font = { kind = 'default', size = 32 } },
      { font = { kind = 'default', spread = 4 } },
      { font = { kind = 'file' } },
      { font = { kind = 'file', file = '' } },
      { font = { kind = 'file', file = 'fonts/ui.ttf', size = 0 } },
      { font = { kind = 'file', file = 'fonts/ui.ttf', spread = math.huge } },
      { font = { kind = 'file', file = 'fonts/ui.ttf', typo = true } },
    }
  do
    expect.raises(function()
      titlebarConfiguration.project(overrides)
    end, 'ui titlebar configuration')
    expect.raises(function()
      config.schema.parse { titlebarStyle = overrides }
    end)
  end
  expect.raises(function()
    config.schema.parse { typo = true }
  end)
end)

return test
