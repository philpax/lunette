local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local theme = require '../private/theme'
local expect = testing.expect
local test = testing.suite()

local MODES: { theme.Mode } = { 'dark', 'light' }

-- Text tokens on the surfaces they are drawn on, with the contrast each pair needs.
local TEXT_PAIRS: { { string } } = {
  { 'ink', 'surface' },
  { 'ink', 'raised' },
  { 'muted', 'surface' },
  { 'bandInk', 'header' },
  { 'headerMuted', 'header' },
  { 'sectionInk', 'section' },
  { 'accentInk', 'accent' },
}

local function contrastOf(resolved: uiHost.Theme, foreground: string, background: string): number
  local colors = resolved.colors :: any
  return theme.contrast(colors[foreground], colors[background])
end

test('text tokens reach 4.5:1 on their surfaces in both modes with the default accent', function()
  for _, mode in MODES do
    local resolved = theme.resolve(mode, theme.DEFAULT_ACCENT)
    for _, pair in TEXT_PAIRS do
      local ratio = contrastOf(resolved, pair[1], pair[2])
      expect.truthy(ratio >= 4.5, `{mode}: {pair[1]} on {pair[2]} is {string.format('%.2f', ratio)}:1`)
    end
  end
end)

test('any accent is guarded to 3:1 against the surface and gets readable ink', function()
  -- A fixed linear congruential sequence keeps the cases the same on every run.
  local seed = 0x10e77e
  local function nextNumber(): number
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  end
  for _ = 1, 200 do
    local accent = { nextNumber(), nextNumber(), nextNumber(), 1 }
    for _, mode in MODES do
      local resolved = theme.resolve(mode, accent)
      local surface = contrastOf(resolved, 'accent', 'surface')
      expect.truthy(surface >= 3, `{mode}: the accent reaches {string.format('%.2f', surface)}:1 against the surface`)
      local ink = contrastOf(resolved, 'accentInk', 'accent')
      expect.truthy(ink >= 4.5, `{mode}: ink on the accent reaches {string.format('%.2f', ink)}:1`)
    end
  end
end)

test('the guard leaves an accent that already contrasts unchanged', function()
  local resolved = theme.resolve('dark', theme.DEFAULT_ACCENT)
  for index = 1, 3 do
    expect.near(resolved.colors.accent[index], theme.DEFAULT_ACCENT[index], 1e-9, `channel {index}`)
  end
end)

test('extreme accents are guarded too', function()
  for _, accent in { { 0, 0, 0, 1 }, { 1, 1, 1, 1 }, { 0.5, 0.5, 0.5, 1 } } do
    for _, mode in MODES do
      local resolved = theme.resolve(mode, accent)
      expect.truthy(contrastOf(resolved, 'accent', 'surface') >= 3, `{mode}: {table.concat(accent, ',')}`)
    end
  end
end)

return test
