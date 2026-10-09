-- Covers dependency direction, ownership impact, and projected pointer transforms without a renderer.

local testing = require '@testing'
local graph = require '@lunette-plugins/desktop/manager/graph'
local expect = testing.expect
local test = testing.suite()

local function snapshot()
  return {
    nodes = {
      { id = 'a', name = 'source', state = 'active', enabled = true },
      { id = 'b', name = 'source', state = 'active', enabled = true },
      { id = 'c', name = 'leaf', state = 'waiting', enabled = true, detail = 'missing sample/service' },
      { id = 'd', name = 'owned', state = 'active', enabled = true },
    },
    edges = {
      { id = 'ab', kind = 'dependency', from = 'b', to = 'a', label = 'sample/service', generation = '4' },
      { id = 'bc', kind = 'dependency', from = 'c', to = 'b', label = 'sample/other', generation = '5' },
      { id = 'ad', kind = 'ownership', from = 'd', to = 'a', label = 'owned child' },
    },
  }
end

local function equalIds(actual, expected, label)
  expect.equal(table.concat(actual, ','), table.concat(expected, ','), label)
end

test('dependency traversal distinguishes direct and transitive forward and reverse bindings', function()
  local state = snapshot()
  equalIds(graph.dependencies(state, 'c', 'forward', false), { 'b' }, 'the direct provider')
  equalIds(graph.dependencies(state, 'c', 'forward', true), { 'a', 'b' }, 'the transitive providers')
  equalIds(graph.dependencies(state, 'a', 'reverse', false), { 'b' }, 'the direct consumer')
  equalIds(graph.dependencies(state, 'a', 'reverse', true), { 'b', 'c' }, 'the transitive consumers')
  equalIds(graph.dependencies(state, 'd', 'forward', true), {}, 'ownership does not imply a service binding')
  equalIds(graph.dependencies(state, 'unknown', 'forward', true), {}, 'an absent node has no recorded bindings')
end)

test('impact includes child ownership and consumers without merging same-name instances', function()
  equalIds(graph.impact(snapshot(), 'a'), { 'b', 'c', 'd' }, 'disable and reload impact')
  equalIds(graph.impact(snapshot(), 'b'), { 'c' }, 'the second source has its own identity')
  equalIds(graph.impact(snapshot(), 'c'), {}, 'a consumer without children affects no other node')
end)

test('duplicate bindings, cycles, and missing origins terminate without dangling traversal', function()
  local state = snapshot()
  state.edges[#state.edges + 1] = { id = 'ca', kind = 'dependency', from = 'a', to = 'c', label = 'cycle' }
  state.edges[#state.edges + 1] = state.edges[1]
  state.edges[#state.edges + 1] = { id = 'missing', kind = 'dependency', from = 'a', to = 'absent', label = 'stale' }
  equalIds(graph.dependencies(state, 'a', 'forward', true), { 'b', 'c' }, 'the cyclic provider closure')
  equalIds(graph.dependencies(state, 'a', 'reverse', true), { 'b', 'c' }, 'the cyclic consumer closure')
  equalIds(graph.impact(state, 'a'), { 'b', 'c', 'd' }, 'the cyclic unload impact')
  local layout = graph.layout(state)
  expect.truthy(layout.a and layout.b and layout.c and layout.d, 'the cyclic graph lays out every node')
  state.edges[#state.edges + 1] = { id = 'dangling', kind = 'dependency', from = 'a', to = 'absent', label = 'gone' }
  state.edges[#state.edges + 1] =
    { id = 'dangling-owner', kind = 'ownership', from = 'b', to = 'absent', label = 'gone' }
  state.edges[#state.edges + 1] =
    { id = 'dangling-from', kind = 'dependency', from = 'absent', to = 'c', label = 'gone' }
  equalIds(graph.dependencies(state, 'absent', 'forward', true), {}, 'missing forward origin')
  equalIds(graph.dependencies(state, 'absent', 'reverse', true), {}, 'missing reverse origin')
  equalIds(graph.impact(state, 'absent'), {}, 'missing ownership origin')
end)

test('search covers instance ids names state and failures as literal case-insensitive text', function()
  equalIds(graph.search(snapshot(), 'SOURCE'), { 'a', 'b' }, 'both same-name instances remain distinct')
  equalIds(graph.search(snapshot(), 'sample/service'), { 'c' }, 'the missing requirement is searchable')
  equalIds(graph.search(snapshot(), 'wait'), { 'c' }, 'the lifecycle state is searchable')
  equalIds(graph.search(snapshot(), '['), {}, 'search does not interpret patterns')
  equalIds(graph.search(snapshot(), ''), { 'a', 'b', 'c', 'd' }, 'the empty query selects every node')
end)

test('pan and zoom preserve pointer coordinates across a range of camera transforms', function()
  for _, zoom in { 0.2, 0.5, 1, 2, 4 } do
    local camera = { x = -15, y = 40, zoom = zoom }
    for _, point in { { x = 0, y = 0 }, { x = 10, y = -30 }, { x = 640, y = 480 } } do
      local world = graph.world(camera, point)
      local projected = graph.screen(camera, world)
      expect.near(projected.x, point.x, 1e-8, 'the x coordinate round-trips')
      expect.near(projected.y, point.y, 1e-8, 'the y coordinate round-trips')
      for _, factor in { 0.01, 0.5, 2, 100 } do
        local changed = graph.zoom(camera, point, factor)
        local anchor = graph.world(changed, point)
        expect.near(anchor.x, world.x, 1e-8, 'zoom retains the pointer world x')
        expect.near(anchor.y, world.y, 1e-8, 'zoom retains the pointer world y')
        expect.truthy(changed.zoom >= 0.2 and changed.zoom <= 4, 'zoom stays bounded')
      end
      local moved = graph.pan(camera, { x = 12, y = -8 })
      local after = graph.screen(moved, world)
      expect.near(after.x, point.x + 12, 1e-8, 'pan moves content in screen x')
      expect.near(after.y, point.y - 8, 1e-8, 'pan moves content in screen y')
    end
  end
end)

test('hit testing selects nodes and exact edges at every supported zoom', function()
  local state = snapshot()
  local layout = graph.layout(state)
  for _, zoom in { 0.2, 0.5, 1, 2, 4 } do
    local camera = { x = -15, y = 40, zoom = zoom }
    local box = layout.b
    local center = graph.screen(camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
    local selected = assert(graph.hit(state, layout, camera, center))
    expect.equal(selected.kind, 'node', 'the rectangle takes precedence')
    expect.equal(selected.id, 'b', 'the exact same-name instance')
    local from, to = graph.endpoints(layout, state.edges[1])
    local midpoint = { x = (from.x + to.x) / 2, y = (from.y + to.y) / 2 }
    local pointer = graph.screen(camera, midpoint)
    local edge = assert(graph.hit(state, layout, camera, pointer))
    expect.equal(edge.kind, 'edge', 'the line is selectable')
    expect.equal(edge.id, 'ab', 'the exact binding edge')
    local close = assert(graph.hit(state, layout, camera, { x = pointer.x, y = pointer.y + 6 }))
    expect.equal(close.id, 'ab', 'the tolerance remains in pixels')
    expect.equal(graph.hit(state, layout, camera, { x = -1000, y = -1000 }), nil, 'background does not select')
  end
end)

test('fit and focus handle empty, missing, ordinary, and oversized graphs', function()
  local empty = graph.fit({}, { x = 640, y = 480 })
  expect.equal(empty.zoom, 1, 'empty graph has the default scale')
  local layout = graph.layout(snapshot())
  local viewport = { x = 640, y = 480 }
  local camera = graph.fit(layout, viewport)
  expect.equal(graph.focus(layout, 'absent', viewport, camera), camera, 'missing focus retains the camera')
  local focused = graph.focus(layout, 'c', viewport, camera)
  local box = layout.c
  local center = graph.screen(focused, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
  expect.near(center.x, 320, 1e-8, 'the focus centers x')
  expect.near(center.y, 240, 1e-8, 'the focus centers y')
  local shortViewport = { x = 640, y = 320 }
  local ordinary = graph.layout(snapshot())
  local contained = graph.fit(ordinary, shortViewport)
  for _, box in ordinary do
    local top = graph.screen(contained, { x = box.x, y = box.y })
    local bottom = graph.screen(contained, { x = box.x + box.width, y = box.y + box.height })
    expect.truthy(
      top.x >= 0 and top.y >= 0 and bottom.x <= shortViewport.x and bottom.y <= shortViewport.y,
      'ordinary containment'
    )
  end
  local nodes = {}
  for index = 1, 20 do
    nodes[index] = { id = tostring(index), name = 'independent', state = 'active', enabled = true }
  end
  local limited = graph.fit(graph.layout { nodes = nodes, edges = {} }, shortViewport)
  expect.equal(limited.zoom, 0.2, 'oversized graphs retain the minimum readable scale')
  local lower = graph.screen(limited, { x = 0, y = 1770 })
  expect.truthy(lower.y > shortViewport.y, 'the oversized graph requires panning')
  local moved = graph.pan(limited, { x = 0, y = -lower.y + shortViewport.y })
  expect.near(graph.screen(moved, { x = 0, y = 1770 }).y, shortViewport.y, 1e-8, 'panning reaches the last row')
end)

test('parallel, reversed, and self-loop relationships keep distinct selectable routes', function()
  local state = snapshot()
  state.edges[#state.edges + 1] = { id = 'ab2', kind = 'dependency', from = 'b', to = 'a', label = 'other contract' }
  state.edges[#state.edges + 1] = { id = 'ab3', kind = 'ownership', from = 'b', to = 'a', label = 'owner' }
  state.edges[#state.edges + 1] = { id = 'reverse', kind = 'dependency', from = 'a', to = 'b', label = 'reverse' }
  state.edges[#state.edges + 1] = { id = 'self1', kind = 'dependency', from = 'a', to = 'a', label = 'self one' }
  state.edges[#state.edges + 1] = { id = 'self2', kind = 'dependency', from = 'a', to = 'a', label = 'self two' }
  local layout = graph.layout(state)
  local camera = { x = 0, y = 0, zoom = 1 }
  for _, index in { 1, 4, 5, 6 } do
    local edge = state.edges[index]
    local route = graph.route(state, layout, camera, edge)
    local selected = assert(graph.hit(state, layout, camera, graph.screen(camera, route[2])))
    expect.equal(selected.kind, 'edge', 'the route midpoint selects an edge')
    expect.equal(selected.id, edge.id, 'each parallel or reversed relationship can be selected')
  end
  for _, index in { 7, 8 } do
    local edge = state.edges[index]
    local route = graph.route(state, layout, camera, edge)
    local selected = assert(graph.hit(state, layout, camera, graph.screen(camera, route[3])))
    expect.equal(selected.kind, 'edge', 'the self-loop leaves the node rectangle')
    expect.equal(selected.id, edge.id, 'each self-loop is individually selectable')
  end
end)

return test
