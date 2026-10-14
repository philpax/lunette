local testing = require '@testing'
local render = require '@testing/render'
local drawing = require '../private/rendering/draw'
local themes = require '../private/rendering/theme'
local expect = testing.expect
local test = testing.suite()

type Theme = themes.Theme<render.Font>
type ThemeChanges = { padding: number?, fontSize: number?, rowHeight: number?, spacing: number? }
type Visual = {
  id: string,
  kind: themes.Kind | 'panel',
  label: string,
  bounds: themes.Bounds,
  clip: themes.Bounds,
  theme: Theme,
  enabled: boolean,
  hovered: boolean,
  pressed: boolean,
  focused: boolean,
  items: { themes.ItemDescription },
  value: string?,
  caret: number?,
  anchor: number?,
  error: string?,
  opened: boolean?,
  overflow: boolean?,
}
type VisualChanges = {
  label: string?,
  bounds: themes.Bounds?,
  clip: themes.Bounds?,
  theme: Theme?,
  items: { themes.ItemDescription }?,
  value: string?,
  caret: number?,
  anchor: number?,
  error: string?,
  opened: boolean?,
  overflow: boolean?,
}
type Renderer = (render.Pass, Visual) -> ()
type Hook = (render.Pass, Visual, Renderer) -> ()

local default: Theme

local function recorderForDrawing(): render.Recorder
  testing.native()
  local recorder = render.new()
  default = themes.materialize(themes.DEFAULT, recorder.font)
  lovr.graphics.getDefaultFont = function(): render.Font
    return recorder.font
  end
  return recorder
end

local function resolve(overrides: ThemeChanges): Theme
  local result = table.clone(default)
  for key, value in overrides do
    result[key] = value
  end
  return table.freeze(result)
end

local function draw(pass: render.Pass, visual: Visual, hook: Hook?)
  drawing.render(pass, visual, hook, drawing.newCache())
end

local function visual(kind: themes.Kind | 'panel', changes: VisualChanges?): Visual
  local value: Visual = {
    id = 'control',
    kind = kind,
    label = 'A long label',
    bounds = { x = -10, y = -5, width = 120, height = 70 },
    clip = { x = 0, y = 0, width = 100, height = 60 },
    theme = default,
    enabled = true,
    hovered = true,
    pressed = false,
    focused = true,
    items = {},
  }
  for key, replacement in changes or {} do
    value[key] = replacement
  end
  return value
end

local function texts(recorder: render.Recorder): { render.Argument }
  local result: { render.Argument } = {}
  for _, call in recorder.calls do
    if call[1] == 'text' then
      table.insert(result, call[2])
    end
    expect.truthy(call[1] ~= 'setScissor', 'no framebuffer clipping')
  end
  return result
end

test('every built-in visual clips before a posed parent transform and restores caller state', function()
  for _, kind in { 'panel', 'button', 'text-field', 'choice', 'list', 'region' } do
    local recorder = recorderForDrawing()
    local pass = recorder.pass
    pass:translate(2, 3, -4)
    pass:rotate(0.7, 0, 1, 0)
    pass:scale(0.001, -0.001, 1)
    pass:setColor(0.1, 0.2, 0.3, 0.4)
    local checkpoint = recorder:checkpoint()
    local value = visual(kind, {
      value = 'abcdef',
      caret = 3,
      anchor = 1,
      error = 'Invalid value',
      opened = true,
      overflow = true,
      items = {
        {
          id = 'first',
          label = 'First',
          enabled = true,
          selected = true,
          bounds = { x = -10, y = -5, width = 120, height = 30 },
        },
        {
          id = 'last',
          label = 'Last',
          enabled = false,
          selected = false,
          bounds = { x = -10, y = 25, width = 120, height = 30 },
          route = { { x = -40, y = 10 }, { x = 140, y = 50 } },
        },
      },
    })
    recorder:within(value.clip, function()
      draw(pass, value)
    end)
    recorder:assertRestored(checkpoint)
    texts(recorder)
  end
end)

test('a control hook receives the visual and wraps the default renderer', function()
  local recorder = recorderForDrawing()
  local order: { string } = {}
  draw(recorder.pass, visual 'button', function(pass: render.Pass, snapshot: Visual, base: Renderer)
    table.insert(order, 'control:before')
    base(pass, snapshot)
    table.insert(order, 'control:after')
  end)
  expect.equal(table.concat(order, ','), 'control:before,control:after')
  recorder:assertRestored()
end)

test('a failing hook restores the pass and preserves its error', function()
  local recorder = recorderForDrawing()
  expect.raises(function()
    draw(recorder.pass, visual 'button', function(pass: render.Pass)
      pass:translate(200, 100, 0)
      pass:setColor(1, 0, 0, 1)
      error('hook sentinel', 0)
    end)
  end, 'hook sentinel')
  recorder:assertRestored()
end)

test('truncation never splits an extended grapheme cluster', function()
  local recorder = recorderForDrawing()
  draw(
    recorder.pass,
    visual('button', {
      label = 'e\u{301}xxxx',
      bounds = { x = 0, y = 0, width = 16, height = 20 },
      clip = { x = 0, y = 0, width = 16, height = 20 },
      theme = resolve { padding = 0, fontSize = 10 },
    })
  )
  expect.equal(texts(recorder)[1], 'e\u{301}…')
end)

test('an open choice keeps its selected value above its rows', function()
  local recorder = recorderForDrawing()
  local value = visual('choice', {
    label = 'Mode',
    value = 'Selected label',
    opened = true,
    bounds = { x = 0, y = 0, width = 200, height = 100 },
    clip = { x = 0, y = 0, width = 200, height = 100 },
    theme = resolve { rowHeight = 30, spacing = 4, padding = 4, fontSize = 10 },
    items = {
      {
        id = 'row',
        label = 'Option',
        enabled = true,
        selected = false,
        bounds = { x = 4, y = 38, width = 192, height = 30 },
      },
    },
  })
  draw(recorder.pass, value)
  local drawn = texts(recorder)
  expect.equal(drawn[1], 'Mode: Selected label')
  expect.equal(drawn[2], 'Option')
end)

local function choiceHeader(changes: VisualChanges): render.Recorder
  local recorder = recorderForDrawing()
  local value = visual('choice', {
    label = 'Audio',
    bounds = { x = 0, y = 0, width = 200, height = 100 },
    clip = { x = 0, y = 0, width = 200, height = 100 },
    theme = resolve { rowHeight = 30, spacing = 4, padding = 4, fontSize = 10 },
  })
  for key, replacement in changes do
    value[key] = replacement
  end
  draw(recorder.pass, value)
  return recorder
end

local function firstText(recorder: render.Recorder): render.Call
  for _, call in recorder.calls do
    if call[1] == 'text' then
      return call
    end
  end
  error('no text was drawn', 2)
end

test('a closed choice header names its label beside its value, centred in the header row', function()
  local header = firstText(choiceHeader { value = 'On' })
  expect.equal(header[2], 'Audio: On', 'the header names the setting and its value')
  expect.equal(header[4], (30 - 10) / 2, 'the text is centred vertically in the header row')
  expect.equal(firstText(choiceHeader {})[2], 'Audio', 'without a value the header shows only the label')
  expect.equal(firstText(choiceHeader { value = '' })[2], 'Audio', 'an empty value shows only the label')
  expect.equal(firstText(choiceHeader { label = '', value = 'On' })[2], 'On', 'an empty label shows only the value')
end)

local function chevron(opened: boolean): (number, number)
  local recorder = choiceHeader { value = 'On', opened = opened }
  local points: { { x: number, y: number } } = {}
  for _, call in recorder.calls do
    if call[1] == 'line' then
      table.insert(points, { x = call[2] :: number, y = call[3] :: number })
      table.insert(points, { x = call[5] :: number, y = call[6] :: number })
    end
  end
  expect.equal(#points, 4, 'the indicator is two strokes')
  expect.equal(points[2].x, points[3].x, 'the strokes meet at the tip')
  expect.truthy(points[1].x > 200 - 30, 'the indicator sits at the right of the header')
  return points[2].y, points[1].y
end

test('a choice header shows whether it is open with a chevron', function()
  local tip, edge = chevron(false)
  expect.truthy(tip > edge, 'a closed choice points down')
  tip, edge = chevron(true)
  expect.truthy(tip < edge, 'an open choice points up')
end)

return test
