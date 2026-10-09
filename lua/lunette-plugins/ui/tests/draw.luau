local testing = require '@testing'
local render = require '@testing/render'
local lunette = require '@lunette'
local drawing = require '../draw'
local drawCache = drawing.newCache()
local draw = {
  render = function(pass, visual, hooks)
    drawing.render(pass, visual, hooks, drawCache)
  end,
}
local themes = require '../theme'
local theme = {
  resolve = function(base, overrides)
    local result = table.clone(base)
    for key, value in overrides do
      result[key] = value
    end
    return table.freeze(result)
  end,
}
local textField = require '../text-field'
local expect = testing.expect
local test = testing.suite()

local function recorderForDrawing()
  testing.native()
  local recorder = render.new()
  theme.DEFAULT = themes.materialize(themes.DEFAULT, recorder.font)
  drawCache = drawing.newCache()
  lovr.graphics.getDefaultFont = function()
    return recorder.font
  end
  return recorder
end

local function visual(kind, changes)
  local value = {
    id = 'control',
    kind = kind,
    label = 'A long label',
    bounds = { x = -10, y = -5, width = 120, height = 70 },
    clip = { x = 0, y = 0, width = 100, height = 60 },
    theme = theme.DEFAULT,
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
      draw.render(pass, value)
    end)
    recorder:assertRestored(checkpoint)
    expect.truthy(#recorder.calls > 5)
    texts(recorder)
    expect.equal(value.bounds.x, -10)
  end
end)

test('provider, panel, and control hooks receive visuals and paint in precedence order', function()
  local recorder = recorderForDrawing()
  local order = {}
  local function hook(name)
    return function(pass, snapshot, base)
      table.insert(order, name .. ':before')
      base(pass, snapshot)
      table.insert(order, name .. ':after')
    end
  end
  draw.render(recorder.pass, visual 'button', { hook 'provider', hook 'panel', hook 'control' })
  expect.equal(
    table.concat(order, ','),
    'control:before,panel:before,provider:before,provider:after,panel:after,control:after'
  )
  recorder:assertRestored()
end)

test('hooks cannot replace declared geometry through their base renderer', function()
  local recorder = recorderForDrawing()
  local value = visual 'button'
  expect.raises(function()
    draw.render(recorder.pass, value, {
      function(pass, snapshot, base)
        local shifted = table.clone(snapshot)
        shifted.bounds = { x = 1000, y = 1000, width = 10, height = 10 }
        base(pass, shifted)
      end,
    })
  end, 'geometry')
  expect.equal(value.bounds.x, -10)
  recorder:assertRestored()
end)

test('hook and built-in failures restore both pass stacks and preserve the original error', function()
  local recorder = recorderForDrawing()
  expect.raises(function()
    draw.render(recorder.pass, visual 'button', {
      function(pass)
        pass:translate(200, 100, 0)
        pass:setColor(1, 0, 0, 1)
        error('hook sentinel', 0)
      end,
    })
  end, 'hook sentinel')
  recorder:assertRestored()
  recorder.font.getWidth = function()
    error('font sentinel', 0)
  end
  expect.raises(function()
    draw.render(recorder.pass, visual 'button')
  end, 'font sentinel')
  recorder:assertRestored()
end)

test('truncation uses production extended-grapheme boundaries without splitting clusters', function()
  local recorder = recorderForDrawing()
  local combining, emoji = 'é', '👩‍💻'
  expect.equal(#lunette.textBoundaries(combining), 2)
  for _, text in { combining .. 'xxxxxx', emoji .. 'xxxxxx' } do
    draw.render(
      recorder.pass,
      visual('button', {
        label = text,
        bounds = { x = 0, y = 0, width = 34, height = 30 },
        clip = { x = 0, y = 0, width = 34, height = 30 },
        theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 10 }),
      })
    )
  end
  for _, text in texts(recorder) do
    expect.truthy(utf8.len(text))
    expect.truthy(text ~= 'e…' and text ~= '👩…' and text ~= '👩‍…', 'cluster remains whole')
  end
  local narrow = recorderForDrawing()
  draw.render(
    narrow.pass,
    visual('button', {
      label = combining .. 'xxxx',
      bounds = { x = 0, y = 0, width = 16, height = 20 },
      clip = { x = 0, y = 0, width = 16, height = 20 },
      theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 10 }),
    })
  )
  expect.equal(texts(narrow)[1], combining .. '…')
end)

test('text-field pointer selects the boundary drawn in a scrolled, clipped, short field', function()
  local cases = {
    { bounds = { x = 0, y = 0, width = 40, height = 30 }, clip = { x = 0, y = 0, width = 40, height = 30 } },
    { bounds = { x = 0, y = 0, width = 200, height = 12 }, clip = { x = 0, y = 0, width = 200, height = 12 } },
    { bounds = { x = -10, y = -4, width = 60, height = 24 }, clip = { x = 0, y = 0, width = 35, height = 12 } },
  }
  for _, case in cases do
    local recorder = recorderForDrawing()
    local style = theme.resolve(theme.DEFAULT, { padding = 2, fontSize = 20 })
    local source = 'abcdefghijklmnopqrst'
    local widget
    local host = {
      live = function()
        return true
      end,
      changed = function() end,
      cancel = function() end,
      focus = function()
        widget.onFocus(true)
        return true
      end,
      blur = function()
        widget.onFocus(false)
        return true
      end,
      bounds = function()
        return case.bounds
      end,
      clip = function()
        return case.clip
      end,
      theme = function()
        return style
      end,
      callback = function(_, run)
        run()
        return true
      end,
    }
    widget = textField.new({ id = 'entry', bounds = case.bounds, value = source }, host)
    local before = widget.visual(visual('text-field', { bounds = case.bounds, clip = case.clip, theme = style }))
    recorder:within(case.clip, function()
      draw.render(recorder.pass, before)
    end)
    local command
    for _, call in recorder.calls do
      if call[1] == 'text' then
        command = call
        break
      end
    end
    expect.truthy(command, 'visible text exists')
    expect.truthy(#command[2] >= 2, 'at least one interior boundary is visible')
    local first = assert(source:find(command[2], 1, true))
    local x = command[3] + recorder.font:getWidth(command[2]:sub(1, 1)) * command[6]
    widget.pointer {
      pointer = 'right',
      kind = 'press',
      button = 'left',
      captured = true,
      inside = true,
      x = x,
      y = command[4] + 1,
    }
    local caret = widget.methods.selection {}
    expect.equal(caret, first + 1, 'a click reaches the emitted interior boundary')
    recorder:assertRestored()
  end
end)

test('choice draws its selected value when closed and retains its header above open rows', function()
  for _, opened in { false, true } do
    local recorder = recorderForDrawing()
    local value = visual('choice', {
      label = 'Choose an option',
      value = 'Selected label',
      opened = opened,
      bounds = { x = 0, y = 0, width = 200, height = 100 },
      clip = { x = 0, y = 0, width = 200, height = 100 },
      theme = theme.resolve(theme.DEFAULT, { rowHeight = 30, spacing = 4, padding = 4, fontSize = 10 }),
      items = if opened
        then {
          {
            id = 'row',
            label = 'Another option',
            enabled = true,
            selected = false,
            bounds = { x = 4, y = 38, width = 192, height = 30 },
          },
        }
        else {},
    })
    recorder:within(value.clip, function()
      draw.render(recorder.pass, value)
    end)
    expect.equal(texts(recorder)[1], 'Selected label')
    if opened then
      expect.equal(texts(recorder)[2], 'Another option')
    end
    recorder:assertRestored()
  end
end)

test('cached truncation refreshes when font metrics, theme, or clip changes', function()
  local recorder = recorderForDrawing()
  local density = 1
  recorder.font.getPixelDensity = function()
    return density
  end
  recorder.font.getWidth = function(_, value)
    return (utf8.len(value) :: number) * 0.5 / density
  end
  local bounds = { x = 0, y = 0, width = 14, height = 10 }
  local value = visual('button', {
    label = 'abcdef',
    bounds = bounds,
    clip = bounds,
    theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 10 }),
  })
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[1], 'a…')
  density = 2
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[2], 'abcd…')
  value.theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 5 })
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[3], 'abcdef')
  value.clip = { x = 0, y = 0, width = 6, height = 10 }
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[4], 'abc…')
  recorder.font.getWidth = function(_, text)
    return (utf8.len(text) :: number) * 0.1
  end
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[5], 'abcdef')
  local replacement = render.new().font
  local replaced = table.clone(value.theme)
  replaced.font = replacement
  value.theme = table.freeze(replaced)
  lovr.graphics.getDefaultFont = function()
    return replacement
  end
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[6], 'a…', 'a different font does not reuse the previous font metrics')
end)

return test
