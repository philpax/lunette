local testing = require '@testing'
local render = require '@testing/render'
local lunette = require '@lunette'
local draw = require '../draw'
local theme = require '../theme'
local textField = require '../text-field'
local expect = testing.expect
local test = testing.suite()

local function recorderForDrawing()
  testing.native()
  local recorder = render.new()
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

test('provider, panel, and control hooks receive frozen snapshots and paint in precedence order', function()
  local recorder = recorderForDrawing()
  local order = {}
  local function hook(name)
    return function(pass, snapshot, base)
      table.insert(order, name .. ':before')
      expect.truthy(table.isfrozen(snapshot))
      expect.truthy(table.isfrozen(snapshot.bounds))
      expect.truthy(table.isfrozen(snapshot.items))
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

test('textfield selection and caret use measured logical offsets and remain inside the clip', function()
  local recorder = recorderForDrawing()
  local value = visual('text-field', {
    label = '',
    value = 'abcdefghijk',
    caret = 10,
    anchor = 8,
    bounds = { x = 0, y = 0, width = 60, height = 30 },
    clip = { x = 0, y = 0, width = 60, height = 30 },
    theme = theme.resolve(theme.DEFAULT, { padding = 4, fontSize = 12 }),
  })
  recorder:within(value.clip, function()
    draw.render(recorder.pass, value)
  end)
  local selection = false
  for _, call in recorder.calls do
    if call[1] == 'plane' and call.state.setColor and call.state.setColor[1] == value.theme.selection[1] then
      selection = true
      expect.near(call[5], 12, 0.001, 'two measured six-pixel advances')
    end
  end
  expect.truthy(selection)
  recorder:assertRestored()
end)

test('zero-area visuals emit no drawing and invalid input fails before changing the pass', function()
  local recorder = recorderForDrawing()
  draw.render(recorder.pass, visual('button', { bounds = { x = 0, y = 0, width = 0, height = 10 } }))
  for _, call in recorder.calls do
    expect.falsy(call.draw)
  end
  expect.raises(function()
    draw.render(
      recorder.pass,
      visual('region', {
        items = {
          {
            id = 'bad',
            label = '',
            enabled = true,
            selected = false,
            bounds = { x = 0, y = 0, width = 10, height = 10 },
            route = { { x = math.huge, y = 0 } },
          },
        },
      })
    )
  end)
  recorder:assertRestored()
end)

test('restoration attempts both pops even when transform restoration raises', function()
  local recorder = recorderForDrawing()
  local pop = recorder.pass.pop
  local restored = {}
  recorder.pass.pop = function(pass, kind)
    pop(pass, kind)
    table.insert(restored, kind)
    if kind == 'transform' then
      error('restore sentinel', 0)
    end
  end
  expect.raises(function()
    draw.render(recorder.pass, visual 'button', {
      function()
        error('original sentinel', 0)
      end,
    })
  end, 'original sentinel')
  expect.equal(table.concat(restored, ','), 'transform,state')
  recorder:assertRestored()
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

test('scrolled text-field selection uses the metrics of the emitted substring', function()
  local recorder = recorderForDrawing()
  local ordinary = recorder.font.getWidth
  recorder.font.getWidth = function(self, value)
    return ordinary(self, value) - (if value:find('xA', 1, true) then 0.25 else 0)
  end
  local value = visual('text-field', {
    label = '',
    value = 'xxxxAB',
    caret = 7,
    anchor = 5,
    bounds = { x = 0, y = 0, width = 14, height = 10 },
    clip = { x = 0, y = 0, width = 14, height = 10 },
    theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 10 }),
  })
  recorder:within(value.clip, function()
    draw.render(recorder.pass, value)
  end)
  expect.equal(texts(recorder)[1], 'AB')
  local selected, caret = nil, nil
  for _, call in recorder.calls do
    if call[1] == 'plane' then
      local color = call.state.setColor
      if color[1] == value.theme.selection[1] then
        selected = call
      end
      if color[1] == value.theme.focus[1] and call[5] == 2 and call[6] == 10 then
        caret = call
      end
    end
  end
  expect.truthy(selected)
  expect.equal(selected[2], 5, 'selection starts at displayed text origin')
  expect.equal(selected[5], 10, 'selection spans the displayed A and B')
  expect.truthy(caret)
  expect.equal(caret[2], 11, 'caret starts at the displayed text end')
  recorder:assertRestored()
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

test('unchanged overlong labels avoid repeated prefix measurements across interleaved draws', function()
  local recorder = recorderForDrawing()
  local measurements, bytes = 0, 0
  recorder.font.getWidth = function(_, value)
    measurements += 1
    bytes += #value
    return (utf8.len(value) :: number) * 0.5
  end
  local bounds = { x = 0, y = 0, width = 34, height = 30 }
  local values = {}
  for _, character in { 'a', 'b' } do
    table.insert(
      values,
      visual('button', {
        label = string.rep(character, 10000),
        bounds = bounds,
        clip = bounds,
        theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 10 }),
      })
    )
  end
  for _, value in values do
    draw.render(recorder.pass, value)
  end
  measurements, bytes = 0, 0
  for _ = 1, 4 do
    for _, value in values do
      draw.render(recorder.pass, value)
    end
  end
  expect.equal(texts(recorder)[1], 'aaaaa…')
  expect.equal(texts(recorder)[2], 'bbbbb…')
  expect.equal(measurements, 8, 'only the recorder measures each emitted text on warm draws')
  expect.equal(bytes, 64, 'only eight bytes of emitted text are measured per warm draw')
  recorder:assertRestored()
end)

test('truncation can select a fitting prefix after an overwide prefix', function()
  local recorder = recorderForDrawing()
  local ordinary = recorder.font.getWidth
  recorder.font.getWidth = function(self, value)
    return if value == 'abc…' then 1 else ordinary(self, value)
  end
  local bounds = { x = 0, y = 0, width = 14, height = 10 }
  local value = visual('button', {
    label = 'abcdef',
    bounds = bounds,
    clip = bounds,
    theme = theme.resolve(theme.DEFAULT, { padding = 0, fontSize = 10 }),
  })
  recorder:within(bounds, function()
    draw.render(recorder.pass, value)
    draw.render(recorder.pass, value)
  end)
  expect.equal(texts(recorder)[1], 'abc…')
  expect.equal(texts(recorder)[2], 'abc…')
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
  lovr.graphics.getDefaultFont = function()
    return replacement
  end
  draw.render(recorder.pass, value)
  expect.equal(texts(recorder)[6], 'a…', 'a different font does not reuse the previous font metrics')
end)

return test
