local testing = require '@testing'
local toolbarLayout = require '@lunette-plugins/desktop/manager/toolbar-layout'
local managerConfig = require '@lunette-plugins/desktop/manager/config'
local expect = testing.expect
local test = testing.suite()

type Bounds = toolbarLayout.Bounds

local function overlaps(a: Bounds, b: Bounds): boolean
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

test('the minimum canvas fits every control without overlap', function()
  local width, height = toolbarLayout.minimumWidth, toolbarLayout.minimumHeight
  local layout = toolbarLayout.compute(width, height, true, true, nil, 'graph', 'configure')
  local boxes = { layout.graphBounds, layout.bodyBounds, layout.editBounds, layout.searchBounds }
  for _, id in { 'configure', 'apply', 'recover', 'add', 'zoom-in', 'fit', 'search', 'confirm', 'cancel' } do
    expect.truthy(layout.buttons[id], id .. ' has a placement')
  end
  for _, button in layout.buttons do
    boxes[#boxes + 1] = button.bounds
  end
  for index, box in boxes do
    expect.truthy(box.x >= 0 and box.y >= 0 and box.x + box.width <= width and box.y + box.height <= height)
    for other = index + 1, #boxes do
      expect.falsy(overlaps(box, boxes[other]), 'controls and content do not overlap')
    end
  end
end)

test('configuration rejects a canvas shorter than the layout minimum', function()
  expect.raises(function()
    managerConfig.schema.parse({ width = 5, height = 0.1, pixels = 800 }, 'manager')
  end)
  local minimum = managerConfig.schema.parse { width = 5, height = toolbarLayout.minimumHeight * 5 / 800, pixels = 800 }
  expect.equal(minimum.view, 'entries', 'the entry list is the default view')
end)

return test
