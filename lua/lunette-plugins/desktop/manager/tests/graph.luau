local testing = require '@testing'
local graph = require '@lunette-plugins/desktop/manager/graph'
local expect = testing.expect
local test = testing.suite()

type Snapshot = { nodes: { graph.Node }, edges: { graph.Edge } }

local function snapshot(): Snapshot
  return {
    nodes = {
      { id = 'a', name = 'source', state = 'active', enabled = true },
      { id = 'b', name = 'source', state = 'active', enabled = true },
      { id = 'c', name = 'leaf', state = 'waiting', enabled = true },
      { id = 'd', name = 'owned', state = 'active', enabled = true },
    },
    edges = {
      { id = 'ab', kind = 'dependency', from = 'b', to = 'a', label = 'sample/service' },
      { id = 'bc', kind = 'dependency', from = 'c', to = 'b', label = 'sample/other' },
      { id = 'ad', kind = 'ownership', from = 'd', to = 'a', label = 'owned child' },
    },
  }
end

local function equalIds(actual: { string }, expected: { string }, label: string)
  expect.equal(table.concat(actual, ','), table.concat(expected, ','), label)
end

test('traversal follows bindings by direction and impact includes owned children', function()
  local state = snapshot()
  equalIds(graph.dependencies(state, 'c', 'forward', false), { 'b' }, 'the direct provider')
  equalIds(graph.dependencies(state, 'c', 'forward', true), { 'a', 'b' }, 'the transitive providers')
  equalIds(graph.dependencies(state, 'a', 'reverse', true), { 'b', 'c' }, 'the transitive consumers')
  equalIds(graph.impact(state, 'a'), { 'b', 'c', 'd' }, 'consumers and owned children')
  equalIds(graph.impact(state, 'b'), { 'c' }, 'a same-name instance keeps its own identity')
  state.edges[#state.edges + 1] = { id = 'ca', kind = 'dependency', from = 'a', to = 'c', label = 'cycle' }
  equalIds(graph.dependencies(state, 'a', 'forward', true), { 'b', 'c' }, 'a cycle terminates')
end)

test('hit testing selects nodes before edges and ignores the background', function()
  local state = snapshot()
  local layout = graph.layout(state)
  for _, zoom in { 0.2, 1, 4 } do
    local camera = { x = -15, y = 40, zoom = zoom }
    local box = layout.b
    local center = graph.screen(camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
    local node = assert(graph.hit(state, layout, camera, center))
    expect.equal(node.id, 'b', 'the exact same-name instance')
    local from, to = graph.endpoints(layout, state.edges[1])
    local midpoint = graph.screen(camera, { x = (from.x + to.x) / 2, y = (from.y + to.y) / 2 })
    local edge = assert(graph.hit(state, layout, camera, { x = midpoint.x, y = midpoint.y + 6 }))
    expect.equal(edge.id, 'ab', 'the edge tolerance is in pixels')
    expect.equal(graph.hit(state, layout, camera, { x = -1000, y = -1000 }), nil)
  end
end)

test('zoom keeps the pointed position fixed and pan moves content', function()
  local camera = { x = -15, y = 40, zoom = 1 }
  local point = { x = 10, y = -30 }
  local world = graph.world(camera, point)
  for _, factor in { 0.01, 2, 100 } do
    local changed = graph.zoom(camera, point, factor)
    local anchor = graph.world(changed, point)
    expect.near(anchor.x, world.x, 1e-8)
    expect.near(anchor.y, world.y, 1e-8)
    expect.truthy(changed.zoom >= 0.2 and changed.zoom <= 4, 'zoom stays bounded')
  end
  local after = graph.screen(graph.pan(camera, { x = 12, y = -8 }), world)
  expect.near(after.x, point.x + 12, 1e-8)
  expect.near(after.y, point.y - 8, 1e-8)
end)

return test
