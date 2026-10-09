local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/vr-manager'
local topology = require './support/vr-graph-topology'
local toolbarLayout = require '../toolbar-layout'
local suite = testing.suite()

local test = fixture.testCases(suite, true)

local function control(env, id, itemId)
  return env.controls:discover(env.services.ui, 'desktop/manager', id, itemId)
end

local function graph(env)
  local description, region = control(env, 'graph')
  return region, description
end

local function equalNodes(env, wanted, context)
  local actual, expected = {}, table.clone(wanted)
  for _, item in graph(env).items do
    if item.id:sub(1, 5) == 'node/' then
      actual[#actual + 1] = item.id:sub(6)
    end
  end
  table.sort(actual)
  table.sort(expected)
  expect.equal(#actual, #expected, context .. ' node count')
  expect.equal(table.concat(actual, ','), table.concat(expected, ','), context .. ' exact instance IDs')
end

local function filter(env)
  env:click 'search'
  control(env, 'search-field')
  expect.truthy(env.services.display:isVisible(), 'Search opens the shared keyboard')
  env:key 'All'
  env:key 'Text'
  env:key 'Enter'
end

local function bounds(env, id)
  local _, item = control(env, 'graph', 'node/' .. id)
  return item.bounds
end

local function sameBounds(actual, expected, context)
  for _, field in { 'x', 'y', 'width', 'height' } do
    expect.near(actual[field], expected[field], 0.002, context .. ' ' .. field)
  end
end

local function rendered(env, wanted, inspectionOnly)
  env.native.events.draw = {}
  env.controls:draw()
  local sidebar = graph(env).bounds.width
  for _, call in env.controls:drawCalls 'text' do
    if call[2]:find(wanted, 1, true) and (not inspectionOnly or call[3] >= sidebar) then
      return
    end
  end
  error('inspection does not draw ' .. wanted, 0)
end

local function inside(box, x, y, margin)
  margin = margin or 0
  return x >= box.x - margin
    and x <= box.x + box.width + margin
    and y >= box.y - margin
    and y <= box.y + box.height + margin
end

local function routePoint(env, edgeId)
  local region, description = graph(env)
  local route
  for _, item in region.items do
    if item.id == edgeId then
      route = item.route
    end
  end
  assert(route and #route > 1, 'a relationship publishes its exact polyline')
  for index = 1, #route - 1 do
    local first, last = route[index], route[index + 1]
    for _, fraction in { 0.5, 0.25, 0.75 } do
      local x = first.x + (last.x - first.x) * fraction
      local y = first.y + (last.y - first.y) * fraction
      local covered = false
      for _, item in region.items do
        if item.id:sub(1, 5) == 'node/' and inside(item.bounds, x, y, 8) then
          covered = true
        end
      end
      if inside(region.bounds, x, y, -2) and not covered then
        return description, x, y
      end
    end
  end
  error('the published relationship has no reachable segment outside the nodes: ' .. edgeId, 0)
end

local function reachable(env, id, itemId)
  local description, item = control(env, id, itemId)
  local box = assert(item.bounds, 'a reachable control has bounds')
  expect.truthy(box.width > 0 and box.height > 0, id .. ' has positive bounds')
  expect.truthy(box.x >= 0 and box.y >= 0, id .. ' starts inside the panel')
  expect.truthy(box.x + box.width <= description.logicalWidth + 0.001, id .. ' fits the width')
  expect.truthy(box.y + box.height <= description.logicalHeight + 0.001, id .. ' fits the height')
end

local function selectRow(env, itemId)
  for _ = 1, 32 do
    local description, rows = control(env, 'rows')
    for _, item in rows.items do
      if item.id == itemId then
        reachable(env, 'rows', itemId)
        env:click('rows', itemId)
        return
      end
    end
    local box = rows.bounds
    env.controls:aim(description, box.x + box.width / 2, box.y + box.height / 2, 'right')
    env.controls:axis('right', 0, -1)
    env.controls:step(0.04)
    env.controls:axis('right', 0, 0)
    env.controls:step()
  end
  error('controller scrolling cannot reach the configuration row ' .. itemId, 0)
end

local function sidebarRow(env)
  local _, rows = control(env, 'rows')
  expect.truthy(#rows.items > 0, 'a sidebar row remains published beside the field')
  reachable(env, 'rows', rows.items[1].id)
end

test('manager graph traversal publishes the independent topology through VR controls', function()
  local shape = topology.new 'traversal'
  local env = fixture.boot(shape.entries)
  env:open()
  filter(env)
  local ids = shape:ids(env)
  local all = { ids.provider, ids.middle, ids.leaf, ids.child, ids.unrelated }
  equalNodes(env, all, 'the literal keyboard search')
  env:click('graph', 'node/' .. ids.leaf)
  env:click 'providers'
  equalNodes(env, { ids.leaf, ids.middle }, 'the direct providers')
  env:click 'transitive'
  equalNodes(env, { ids.leaf, ids.middle, ids.provider }, 'the transitive providers')
  env:click 'all'
  equalNodes(env, all, 'All restores every search match')
  env:click('graph', 'node/' .. ids.provider)
  env:click 'transitive'
  env:click 'consumers'
  equalNodes(env, { ids.provider, ids.middle }, 'the direct consumers exclude ownership')
  env:click 'transitive'
  equalNodes(env, { ids.provider, ids.middle, ids.leaf }, 'the transitive consumers')
  env:click 'affected'
  equalNodes(env, { ids.provider, ids.middle, ids.leaf, ids.child }, 'Affected includes the owned child')
  env:click 'all'
  equalNodes(env, all, 'All restores the unrelated instance')
  expect.equal(env:keyboardCount(), 1, 'graph Search uses one shared keyboard')
end)

test('manager selects both parallel relationships from their published VR polylines', function()
  local shape = topology.new 'routes'
  local env = fixture.boot(shape.entries)
  env:open()
  filter(env)
  local ids, edges = shape:ids(env), {}
  for _, item in graph(env).items do
    if item.id:sub(1, 5) == 'edge/' and item.label:find('local/vr-graph-', 1, true) then
      edges[#edges + 1] = { id = item.id, label = item.label }
    end
  end
  expect.equal(#edges, 3, 'two root bindings and one leaf binding publish routes')
  local selected = 0
  for _, edge in edges do
    if edge.label:find('local/vr-graph-first', 1, true) or edge.label:find('local/vr-graph-second', 1, true) then
      local description, x, y = routePoint(env, edge.id)
      env.controls:click(description, x, y, 'right')
      rendered(env, edge.label, true)
      rendered(env, 'dependency: #' .. ids.middle .. ' -> #' .. ids.provider)
      rendered(env, 'Provider generation: ')
      rendered(env, 'Current: true')
      selected += 1
    end
  end
  expect.equal(selected, 2, 'each parallel binding is independently inspected')
end)

test('manager VR camera controls change public geometry and Fit restores it', function()
  local shape = topology.new 'camera'
  local env = fixture.boot(shape.entries)
  env:open()
  filter(env)
  -- Search creates a runtime keyboard instance; fit only after that graph is present.
  env:click 'fit'
  filter(env)
  local ids = shape:ids(env)
  local initial = bounds(env, ids.middle)
  env:click 'zoom-in'
  local enlarged = bounds(env, ids.middle)
  expect.near(enlarged.width / initial.width, 1.2, 0.002, 'Zoom in enlarges the actual node')
  env:click 'zoom-out'
  sameBounds(bounds(env, ids.middle), initial, 'Zoom out reverses the step')
  env:click('graph', 'node/' .. ids.middle)
  env:click 'focus'
  local region, description = graph(env)
  local declared = toolbarLayout.compute(
    description.logicalWidth,
    description.logicalHeight,
    false,
    false,
    nil,
    'graph',
    'inspect'
  ).graphBounds
  local centered = bounds(env, ids.middle)
  expect.near(centered.x + centered.width / 2, declared.x + declared.width / 2, 0.002, 'Focus centers declared x')
  expect.near(centered.y + centered.height / 2, declared.y + declared.height / 2, 0.002, 'Focus centers declared y')
  env.native.events.draw = {}
  env.controls:draw()
  local drawn = false
  for _, face in env.controls:drawCalls 'plane' do
    if
      math.abs(face[2] - centered.x - centered.width / 2) < 0.002
      and math.abs(face[3] - centered.y - centered.height / 2) < 0.002
      and math.abs(face[5] - centered.width) < 0.002
      and math.abs(face[6] - centered.height) < 0.002
    then
      drawn = true
    end
  end
  expect.truthy(drawn, 'Focus draws the node at its published geometry inside the rounded clip')
  local x, y = region.bounds.x + 6, region.bounds.y + 6
  env.controls:aim(description, x, y, 'right')
  env.controls:step()
  env.controls:button('right', 'trigger', true)
  env.controls:step()
  env.controls:aim(description, x + 30, y + 20, 'right')
  env.controls:step()
  -- The public scene stays frozen until the captured gesture releases.
  sameBounds(bounds(env, ids.middle), centered, 'the captured scene remains stable')
  env.controls:button('right', 'trigger', false)
  env.controls:step()
  local panned = bounds(env, ids.middle)
  expect.near(panned.x - centered.x, 30, 0.01, 'released pan translates x')
  expect.near(panned.y - centered.y, 20, 0.01, 'released pan translates y')
  env.controls:aim(env:description(), panned.x + panned.width / 2, panned.y + panned.height / 2, 'right')
  env.controls:axis('right', 0, -1)
  env.controls:step()
  env.controls:axis('right', 0, 0)
  env.controls:step()
  expect.truthy(bounds(env, ids.middle).width < panned.width, 'the real controller axis zooms the canvas out')
  env:click 'search'
  env:click 'fit'
  local fitted = bounds(env, ids.middle)
  env:click 'fit'
  sameBounds(bounds(env, ids.middle), fitted, 'Fit is idempotent after Search')
  filter(env)
  sameBounds(bounds(env, ids.middle), initial, 'Fit restores the original camera')
end)

test('manager minimum canvas keeps VR fields and a sidebar row reachable', function()
  local shape = topology.new 'minimum'
  local env = fixture.boot(shape.entries, { width = 1, height = 472 / 800, pixels = 800 })
  env:open()
  expect.equal(env:description().logicalWidth, 800, 'the minimum logical width')
  expect.near(env:description().logicalHeight, 472, 0.001, 'the minimum logical height')
  env:click 'search'
  reachable(env, 'search-field')
  env:click 'search-field'
  env:key 'Text'
  env:key 'Enter'
  local ids = shape:ids(env)
  env:click('graph', 'node/' .. ids.leaf)
  env:click 'configure'
  selectRow(env, 'row/s:enabled')
  reachable(env, 'boolean-field')
  sidebarRow(env)
  env:click 'boolean-field'
  env:click 'apply'
  expect.equal(shape.settings.enabled, false, 'the minimum-size boolean commits through VR')
  selectRow(env, 'row/s:mode')
  reachable(env, 'choice-field')
  sidebarRow(env)
  env:choice 'choice/2'
  env:click 'apply'
  expect.equal(shape.settings.mode, 'second', 'the minimum-size choice commits through VR')
  selectRow(env, 'row/s:title')
  reachable(env, 'edit-field')
  sidebarRow(env)
  reachable(env, 'confirm')
  env:click 'edit-field'
  env:key 'All'
  env:key 'Text'
  env:click 'confirm'
  env:click 'apply'
  expect.equal(shape.settings.title, 'next', 'the minimum-size text commits through the shared keyboard')
  expect.equal(env:keyboardCount(), 1, 'all minimum-size fields share one keyboard')
end)

test('manager VR Search hands focus to an offered native application and back', function()
  local env = fixture.boot()
  env:open()
  local application, window = topology.application(env)
  env:click 'search'
  local searchFocus = assert(env.services.focus:focused(), 'Search owns the initial text route')
  env.native.events.input = {}
  env.controls:click(application, 500, 250, 'right')
  local buttons = env.controls:nativeCalls 'button'
  expect.equal(#buttons, 2, 'the offered application receives exactly one native press and release')
  expect.equal(buttons[1][2], 'left', 'the trigger maps to the primary native button')
  expect.equal(buttons[1][3], true, 'the native application press')
  expect.equal(buttons[2][3], false, 'the native application release')
  expect.truthy(#env.controls:nativeCalls 'pointer' > 0, 'the native application receives pointer coordinates')
  expect.truthy(env.services.focus:focused() ~= searchFocus, 'the application replaces the public text route')
  local nativeFocused = false
  for _, seat in env.native.events.seats do
    nativeFocused = nativeFocused or seat.focus == window.sink
  end
  expect.truthy(nativeFocused, 'the offered native sink owns native seat focus')
  env:click 'search-field'
  env.native.events.input = {}
  env:key 'Text'
  rendered(env, 'Search: next')
  expect.equal(#env.controls:nativeCalls 'key', 0, 'returning to Search does not type into the application')
end)

return suite
