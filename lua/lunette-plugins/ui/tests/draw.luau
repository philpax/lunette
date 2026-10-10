local testing = require '@testing'
local render = require '@testing/render'
local drawing = require '../draw'
local themes = require '../theme'
local expect = testing.expect
local test = testing.suite()

local default

local function recorderForDrawing()
  testing.native()
  local recorder = render.new()
  default = themes.materialize(themes.DEFAULT, recorder.font)
  lovr.graphics.getDefaultFont = function()
    return recorder.font
  end
  return recorder
end

local function resolve(overrides)
  local result = table.clone(default)
  for key, value in overrides do
    result[key] = value
  end
  return table.freeze(result)
end

local function draw(pass, visual, hook)
  drawing.render(pass, visual, hook, drawing.newCache())
end

local function visual(kind, changes)
  local value = {
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

local function texts(recorder)
  local result = {}
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
  local order = {}
  draw(recorder.pass, visual 'button', function(pass, snapshot, base)
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
    draw(recorder.pass, visual 'button', function(pass)
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
  expect.equal(drawn[1], 'Selected label')
  expect.equal(drawn[2], 'Option')
end)

return test
