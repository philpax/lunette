local testing = require '@testing'
local render = require '@testing/render'
local lunette = require '@lunette'
local geometry = require '../text-field-geometry'
local theme = require '../theme'
local expect = testing.expect
local test = testing.suite()

local measurement = require '../measurement-cache'
local cache = measurement.new()
local function layout(value, caret, anchor, bounds, clip, overrides, font)
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

test('clipped fields use the visible origin and reduced height for both rendering and clicks', function()
  local result = assert(
    layout(
      'abcdefgh',
      9,
      9,
      { x = -10, y = -4, width = 60, height = 24 },
      { x = 0, y = 0, width = 35, height = 8 },
      { padding = 2, fontSize = 20 }
    )
  )
  expect.equal(result.origin.x, 0)
  expect.equal(result.origin.y, 0)
  expect.equal(result.scale, 8)
  expect.equal(result.text, 'abcdefgh')
  expect.equal(geometry.nearest(result, 12), 4)
  expect.equal(result.caretBounds.x, 32)
end)

test('a cluster wider than the field is omitted whole while its caret remains selectable', function()
  local bounds = { x = 0, y = 0, width = 1, height = 10 }
  local value = '👩🏽‍💻'
  local result = assert(layout(value, #value + 1, 1, bounds, bounds, { padding = 0, fontSize = 10 }))
  expect.equal(result.text, '')
  expect.equal(result.start, #value + 1)
  expect.equal(result.finish, #value + 1)
  expect.equal(result.caretBounds.width, 1)
  expect.equal(geometry.nearest(result, 0.5), #value + 1)
  expect.truthy(result.overflow)
end)

test('byte boundaries and hit positions preserve production extended grapheme clusters', function()
  local value = 'a' .. 'é' .. '👩🏽‍💻' .. 'z'
  local boundaries = lunette.textBoundaries(value)
  local bounds = { x = 5, y = 5, width = 200, height = 20 }
  local result = assert(layout(value, #value + 1, 1, bounds, bounds, { padding = 0, fontSize = 10 }))
  for index, boundary in boundaries do
    expect.equal(result.boundaries[index], boundary)
    expect.equal(geometry.nearest(result, result.positions[index]), boundary)
  end
  expect.raises(function()
    layout(value, 3, 1, bounds, bounds)
  end, 'boundary')
  expect.truthy(table.isfrozen(result))
  expect.truthy(table.isfrozen(result.boundaries))
  expect.truthy(table.isfrozen(result.positions))
  expect.truthy(table.isfrozen(result.origin))
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

test('cached layouts follow changed selection, bounds, clip, theme, and font identity', function()
  local font = render.new().font
  local bounds = { x = 0, y = 0, width = 40, height = 30 }
  local style = { padding = 2, fontSize = 20 }
  local first = assert(layout('abcdef', 7, 7, bounds, bounds, style, font))
  expect.equal(first.text, 'def')
  local selected = assert(layout('abcdef', 7, 5, bounds, bounds, style, font))
  expect.equal(selected.selectionBounds.x, 12)
  expect.equal(selected.selectionBounds.width, 20)
  local moved = assert(layout('abcdef', 3, 5, bounds, bounds, style, font))
  expect.equal(moved.text, 'abc')
  expect.equal(moved.caretBounds.x, 22)
  local clip = { x = 10, y = 0, width = 28, height = 30 }
  local clipped = assert(layout('abcdef', 7, 7, bounds, clip, style, font))
  expect.equal(clipped.text, 'ef')
  expect.equal(clipped.origin.x, 10)
  expect.equal(clipped.caretBounds.x, 30)
  local shifted = { x = 10, y = 4, width = 40, height = 30 }
  local shiftedLayout = assert(layout('abcdef', 7, 7, shifted, shifted, style, font))
  expect.equal(shiftedLayout.origin.x, 12)
  expect.equal(shiftedLayout.origin.y, 6)
  local small = assert(layout('abcdef', 7, 7, bounds, bounds, { padding = 2, fontSize = 10 }, font))
  expect.equal(small.text, 'abcdef')
  expect.equal(small.caretBounds.x, 32)
  local padded = assert(layout('abcdef', 7, 7, bounds, bounds, { padding = 8, fontSize = 20 }, font))
  expect.equal(padded.text, 'def')
  expect.equal(padded.origin.x, 8)
  expect.equal(padded.scale, 14)
  local replacement = render.new().font
  replacement.getWidth = function(_, value)
    return #value * 0.25
  end
  local replaced = assert(layout('abcdef', 7, 7, bounds, bounds, style, replacement))
  expect.equal(replaced.text, 'abcdef')
  expect.equal(replaced.caretBounds.x, 32)
  expect.raises(function()
    layout('é', 2, 1, bounds, bounds, style, font)
  end, 'boundary')
end)

return test
