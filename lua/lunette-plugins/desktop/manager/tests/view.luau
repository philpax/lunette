-- Covers input state independently from projected drawing and composition mutations.

local testing = require '@testing'
local graph = require '@lunette-plugins/desktop/manager/graph'
local view = require '@lunette-plugins/desktop/manager/view'
local expect = testing.expect
local test = testing.suite()

local function fixture()
  local state = view.new { x = 640, y = 480 }
  view.update(state, {
    nodes = {
      { id = 'a', name = 'source', state = 'active', enabled = true },
      { id = 'b', name = 'consumer', state = 'active', enabled = true },
      { id = 'c', name = 'leaf', state = 'active', enabled = true },
    },
    edges = {
      { id = 'ab', kind = 'dependency', from = 'b', to = 'a', label = 'service' },
      { id = 'bc', kind = 'dependency', from = 'c', to = 'b', label = 'service' },
    },
  })
  return state
end

local function count(set)
  local total = 0
  for _, enabled in set do
    if enabled then
      total += 1
    end
  end
  return total
end

test('click selects an instance and dragging pans without changing selection', function()
  local state = fixture()
  local box = state.layout.b
  local point = graph.screen(state.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
  view.press(state, point)
  view.release(state, point)
  expect.equal(state.selection.id, 'b', 'the clicked instance')
  local before = state.camera
  view.press(state, point)
  view.move(state, { x = point.x + 20, y = point.y - 10 })
  view.release(state, { x = point.x + 20, y = point.y - 10 })
  expect.equal(state.selection.id, 'b', 'drag preserves selection')
  expect.near(state.camera.x, before.x - 20 / before.zoom, 1e-8, 'drag pans x')
  expect.equal(state.dragging, nil, 'release ends dragging')
  view.press(state, point)
  view.cancel(state)
  expect.equal(state.dragging, nil, 'pointer departure ends dragging')
end)

local function selectionPoint(state, kind)
  if kind == 'node' then
    local box = state.layout.b
    return graph.screen(state.camera, { x = box.x, y = box.y + box.height / 2 })
  end
  local edge = graph.edge(state.snapshot, 'ab')
  return graph.screen(state.camera, graph.route(state.snapshot, state.layout, state.camera, edge)[2])
end

local function expectSelection(state, kind)
  expect.truthy(state.selection, 'the pressed graph item is selected')
  expect.equal(state.selection.kind, kind, 'the selected item kind')
  expect.equal(state.selection.id, if kind == 'node' then 'b' else 'ab', 'the selected item id')
end

local ZOOM = 0.5

test('a press with small movement or jitter selects the pressed node or edge', function()
  for _, kind in { 'node', 'edge' } do
    for _, offset in { 0.1, 1, 4 } do
      local state = fixture()
      state.camera = { x = 0, y = 0, zoom = ZOOM }
      local point = selectionPoint(state, kind)
      local before = state.camera
      view.press(state, point)
      view.move(state, { x = point.x - offset, y = point.y })
      view.release(state, { x = point.x - offset, y = point.y })
      expectSelection(state, kind)
      expect.equal(state.camera, before, 'click jitter does not pan')
      expect.equal(state.dragging, nil, 'release ends the gesture')
    end
    local state = fixture()
    state.camera = { x = 0, y = 0, zoom = ZOOM }
    local point = selectionPoint(state, kind)
    local before = state.camera
    view.press(state, point)
    for _ = 1, 4 do
      view.move(state, { x = point.x - 4, y = point.y })
      view.move(state, point)
    end
    view.release(state, point)
    expectSelection(state, kind)
    expect.equal(state.camera, before, 'returning jitter never pans')
  end
end)

test('movement past the threshold pans without selecting, including release-only displacement', function()
  for _, kind in { 'node', 'edge' } do
    local state = fixture()
    state.camera = { x = 0, y = 0, zoom = ZOOM }
    view.select(state, { kind = 'node', id = 'c' })
    local point = selectionPoint(state, kind)
    local before = state.camera
    view.press(state, point)
    for offset = 1, 4 do
      view.move(state, { x = point.x + offset, y = point.y })
    end
    expect.equal(state.camera, before, 'movement below the threshold stays pending')
    for offset = 5, 20 do
      view.move(state, { x = point.x + offset, y = point.y })
    end
    expect.near(state.camera.x, before.x - 20 / ZOOM, 1e-8, 'drag includes the full press displacement')
    view.release(state, { x = point.x + 20, y = point.y + 3 })
    expect.equal(state.selection.id, 'c', 'drag release preserves the previous selection')
    expect.near(state.camera.y, before.y - 3 / ZOOM, 1e-8, 'release includes an undelivered final move')

    state = fixture()
    state.camera = { x = 0, y = 0, zoom = ZOOM }
    view.select(state, { kind = 'node', id = 'c' })
    point = selectionPoint(state, kind)
    before = state.camera
    view.press(state, point)
    view.move(state, { x = point.x + 20, y = point.y - 10 })
    expect.near(state.camera.x, before.x - 20 / ZOOM, 1e-8, 'a large move pans')
    view.move(state, point)
    view.release(state, point)
    expect.equal(state.selection.id, 'c', 'returning a drag does not select the pressed item')
    expect.near(state.camera.x, before.x, 1e-8, 'returning the drag restores camera x')
    expect.near(state.camera.y, before.y, 1e-8, 'returning the drag restores camera y')

    for _, offset in { 4, 20 } do
      state = fixture()
      state.camera = { x = 0, y = 0, zoom = ZOOM }
      view.select(state, { kind = 'node', id = 'c' })
      point = selectionPoint(state, kind)
      before = state.camera
      view.press(state, point)
      view.release(state, { x = point.x - offset, y = point.y })
      if offset == 4 then
        expectSelection(state, kind)
        expect.equal(state.camera, before, 'a small release-only move does not pan')
      else
        expect.equal(state.selection.id, 'c', 'a large release-only move does not select')
        expect.near(state.camera.x, before.x + offset / ZOOM, 1e-8, 'a large release-only move pans')
      end
      expect.equal(state.dragging, nil, 'release clears capture')
    end
  end
end)

test('cancel discards a pending click or drag for both nodes and edges', function()
  for _, kind in { 'node', 'edge' } do
    for _, offset in { 0.1, 20 } do
      local state = fixture()
      state.camera = { x = 0, y = 0, zoom = ZOOM }
      view.select(state, { kind = 'node', id = 'c' })
      local point = selectionPoint(state, kind)
      view.press(state, point)
      view.move(state, { x = point.x + offset, y = point.y })
      view.cancel(state)
      local cancelled = state.camera
      view.move(state, point)
      view.release(state, point)
      expect.equal(state.camera, cancelled, 'cancelled input cannot resume panning')
      expect.equal(state.selection.id, 'c', 'a cancelled release cannot select')
      expect.equal(state.dragging, nil, 'cancel clears capture')
      point = selectionPoint(state, kind)
      view.press(state, point)
      view.release(state, point)
      expectSelection(state, kind)
    end
  end
end)

test('search uses complete caller values and ends entry without clearing its filter', function()
  local state = fixture()
  expect.falsy(state.searchActive, 'search initially has no input focus')
  view.search(state)
  expect.truthy(state.searchActive, 'the domain action begins search entry')
  view.setSearch(state, 'source\u{1f50d}')
  expect.equal(state.query, 'source\u{1f50d}', 'the caller Unicode value is intact')
  view.setSearch(state, 'source')
  expect.equal(state.query, 'source', 'the caller replaces the whole value')
  expect.equal(count(view.visible(state)), 1, 'search filters the visible nodes')
  view.endSearch(state)
  expect.falsy(state.searchActive, 'completion closes search entry')
  expect.equal(state.query, 'source', 'completion leaves the current filter')
end)

test('dependency filters distinguish directions and direct versus transitive nodes', function()
  local state = fixture()
  view.select(state, { kind = 'node', id = 'a' })
  state.mode = 'consumers'
  local direct = view.visible(state)
  expect.truthy(direct.a and direct.b, 'the origin and direct consumer are visible')
  expect.falsy(direct.c, 'the transitive consumer is hidden')
  state.transitive = true
  expect.equal(count(view.visible(state)), 3, 'transitive consumers are visible')
  view.select(state, { kind = 'node', id = 'c' })
  state.mode = 'providers'
  expect.equal(count(view.visible(state)), 3, 'transitive providers are visible')
  state.transitive = false
  local providers = view.visible(state)
  expect.truthy(providers.b and providers.c, 'the selected node and direct provider are visible')
  expect.falsy(providers.a, 'the transitive provider is hidden')
  state.mode = 'impact'
  expect.equal(count(view.visible(state)), 1, 'a leaf affects only itself')
end)

test('snapshot updates retain stable selections and discard removed instance or edge ids', function()
  local state = fixture()
  view.select(state, { kind = 'node', id = 'a' })
  view.update(state, state.snapshot)
  expect.equal(state.selection.id, 'a', 'the stable instance remains selected')
  view.select(state, { kind = 'edge', id = 'ab' })
  view.update(state, { nodes = state.snapshot.nodes, edges = {} })
  expect.equal(state.selection, nil, 'a removed binding is no longer selected')
  view.select(state, { kind = 'node', id = 'a' })
  view.update(state, { nodes = {}, edges = {} })
  expect.equal(state.selection, nil, 'a removed instance is no longer selected')
end)

test('filtered-out nodes cannot be selected and reset restores the whole graph', function()
  local state = fixture()
  state.query = 'source'
  local box = state.layout.c
  local point = graph.screen(state.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
  view.press(state, point)
  view.release(state, point)
  expect.equal(state.selection, nil, 'an invisible rectangle does not select')
  state.mode = 'impact'
  state.searchActive = true
  view.reset(state)
  expect.equal(state.mode, 'all', 'reset clears the dependency filter')
  expect.equal(state.query, '', 'reset clears search')
  expect.equal(count(view.visible(state)), 3, 'reset shows every node')
end)

return test
