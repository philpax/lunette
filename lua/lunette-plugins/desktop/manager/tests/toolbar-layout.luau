local testing = require '@testing'
local toolbarLayout = require '@lunette-plugins/desktop/manager/toolbar-layout'
local expect = testing.expect
local test = testing.suite()

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function inside(box, width, height)
  expect.truthy(box.width > 0 and box.height > 0, 'a usable extent')
  expect.truthy(box.x >= 0 and box.y >= 0, 'a nonnegative origin')
  expect.truthy(box.x + box.width <= width and box.y + box.height <= height, 'inside the canvas')
end

for _, editing in { false, true } do
  for _, searching in { false, true } do
    local label = 'minimum canvas with editing ' .. tostring(editing) .. ' and searching ' .. tostring(searching)
    test(label .. ' separates controls and content', function()
      local width, height = toolbarLayout.minimumWidth, toolbarLayout.minimumHeight
      local layout = toolbarLayout.compute(width, height, editing, searching, nil, 'graph', 'configure')
      local boxes = { layout.graphBounds, layout.bodyBounds }
      for _, id in
        {
          'inspect',
          'configure',
          'catalog',
          'enable',
          'disable',
          'reload',
          'recover',
          'remove',
          'apply',
          'optional',
          'reset',
          'add',
          'remove-value',
          'transitive',
          'providers',
          'consumers',
          'all',
          'affected',
          'zoom-in',
          'zoom-out',
          'focus',
          'fit',
          'search',
          'clear-filter',
          'clear-selection',
        }
      do
        expect.truthy(layout.buttons[id], id .. ' has a reachable placement')
      end
      local catalog = toolbarLayout.compute(width, height, editing, searching, nil, 'graph', 'catalog')
      expect.truthy(catalog.buttons.load, 'load has a reachable placement in the catalog')
      expect.truthy(layout.bodyBounds.height >= 36, 'at least one body row')
      expect.truthy(layout.graphBounds.width >= 100 and layout.graphBounds.height >= 100, 'a usable graph canvas')
      for id, button in layout.buttons do
        expect.truthy(id ~= '', 'an explicit action identity')
        expect.truthy(button.group == 'sidebar' or button.group == 'graph' or button.group == 'edit', 'a control group')
        boxes[#boxes + 1] = button.bounds
      end
      if editing then
        expect.truthy(layout.editBounds, 'the active field has bounds')
        boxes[#boxes + 1] = layout.editBounds
        for _, id in { 'confirm', 'cancel', 'clear' } do
          expect.equal(layout.buttons[id].group, 'edit', 'text actions are reachable')
        end
      else
        expect.equal(layout.editBounds, nil, 'inactive fields reserve no controls')
      end
      if searching then
        expect.truthy(layout.searchBounds, 'search has bounds')
        boxes[#boxes + 1] = layout.searchBounds
      end
      for index, box in boxes do
        inside(box, width, height)
        for other = index + 1, #boxes do
          expect.falsy(overlaps(box, boxes[other]), 'controls and content do not overlap')
        end
      end
    end)
  end
end

test('layout is deterministic across larger finite canvases', function()
  for _, size in { { 800, 472 }, { 1280, 800 }, { 2400, 120000 } } do
    local first = toolbarLayout.compute(size[1], size[2], true, true, nil, 'graph', 'configure')
    local second = toolbarLayout.compute(size[1], size[2], true, true, nil, 'graph', 'configure')
    expect.equal(first.graphBounds.y, second.graphBounds.y, 'the graph origin is deterministic')
    expect.equal(first.bodyBounds.height, second.bodyBounds.height, 'the body extent is deterministic')
    for id, button in first.buttons do
      inside(button.bounds, size[1], size[2])
      expect.equal(button.bounds.x, second.buttons[id].bounds.x, 'button placement is deterministic')
    end
  end
end)

test('layout rejects nonfinite and undersized canvases', function()
  for _, size in { { 799, 472 }, { 800, 471 }, { math.huge, 800 }, { 800, math.huge }, { 0 / 0, 800 }, { 800, 0 / 0 } } do
    expect.raises(function()
      toolbarLayout.compute(size[1], size[2], true, true, nil, 'graph', 'configure')
    end, nil, 'invalid dimensions')
  end
end)

for _, valueField in { 'boolean', 'choice' } do
  test(valueField .. ' widgets reserve a separate field while keeping a minimum body row', function()
    local width, height = toolbarLayout.minimumWidth, toolbarLayout.minimumHeight
    local layout = toolbarLayout.compute(width, height, false, true, valueField, 'graph', 'configure')
    expect.truthy(layout.editBounds, 'the value field is present')
    inside(layout.editBounds, width, height)
    if valueField == 'choice' then
      expect.truthy(layout.editBounds.height >= 102, 'the default header and one option fit')
      expect.truthy(layout.editBounds.y + layout.editBounds.height <= height - 56, 'options do not cover the footer')
    end
    expect.truthy(layout.bodyBounds.height >= 36, 'one body row remains')
    expect.falsy(overlaps(layout.bodyBounds, layout.editBounds), 'the field does not overlap rows')
    for id, button in layout.buttons do
      expect.falsy(overlaps(button.bounds, layout.editBounds), id .. ' does not overlap the field')
    end
    for _, id in { 'confirm', 'cancel', 'clear' } do
      expect.equal(layout.buttons[id], nil, 'value widgets do not expose text actions')
    end
  end)
end

return test
