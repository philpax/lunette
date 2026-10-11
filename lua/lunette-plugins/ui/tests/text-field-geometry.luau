local testing = require '@testing'
local render = require '@testing/render'
local lunette = require '@lunette'
local geometry = require '../text-field-geometry'
local theme = require '../theme'
local expect = testing.expect
local test = testing.suite()

local measurement = require '../measurement-cache'
local cache = measurement.new()
type ui = typeof(require '@lunette-contracts/ui')

local function layout(
  value: string,
  caret: number,
  anchor: number,
  bounds: ui.Bounds,
  clip: ui.Bounds,
  overrides: ui.ThemeOverrides?,
  font: render.Font?
): geometry.Layout?
  font = font or render.new().font
  return geometry.layout(
    value,
    caret,
    anchor,
    bounds,
    clip,
    theme.materialize(theme.inherit(theme.DEFAULT, overrides), font),
    font,
    cache
  )
end

test('long values scroll at whole clusters and expose measured visible click positions', function()
  local value = 'abcdefghijklmnopqrst'
  local bounds = { x = 0, y = 0, width = 40, height = 30 }
  local result = assert(layout(value, 21, 19, bounds, bounds, { padding = 2, fontSize = 20 }))
  expect.equal(result.text, 'rst')
  expect.equal(result.start, 18)
  expect.equal(result.finish, 21)
  expect.equal(result.origin.x, 2)
  expect.equal(result.scale, 20)
  expect.equal(result.caretBounds.x, 32)
  expect.equal(result.selectionBounds.x, 12)
  expect.equal(result.selectionBounds.width, 20)
  expect.equal(geometry.nearest(result, 12), 19)
  expect.equal(geometry.nearest(result, -100), 18)
  expect.equal(geometry.nearest(result, 1000), 21)
end)

test('visible positions remain within the clip across values, caret positions, and short heights', function()
  for _, value in { '', 'a', 'abcdef', 'éx👩🏽‍💻z', 'xxxxxxxxxxxxxxxxxxxx' } do
    for _, caret in lunette.textBoundaries(value) do
      for _, height in { 1, 6, 20 } do
        local bounds = { x = -5, y = -2, width = 35, height = 30 }
        local clip = { x = 0, y = 0, width = 25, height = height }
        local result = assert(layout(value, caret, 1, bounds, clip, { padding = 0, fontSize = 20 }))
        expect.truthy(result.start <= caret and result.finish >= caret)
        expect.truthy(result.caretBounds.x >= result.visible.x)
        expect.truthy(result.caretBounds.x + result.caretBounds.width <= result.visible.x + result.visible.width)
        expect.truthy(result.scale * render.new().font:getHeight() <= result.visible.height)
        for index, x in result.positions do
          expect.truthy(x >= result.visible.x and x <= result.visible.x + result.visible.width)
          if index == 1 or x > result.positions[index - 1] then
            expect.equal(geometry.nearest(result, x), result.boundaries[index])
          end
        end
      end
    end
  end
end)

return test
