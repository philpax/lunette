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
    },
    edges = { { id = 'ab', kind = 'dependency', from = 'b', to = 'a', label = 'service' } },
  })
  state.camera = { x = 0, y = 0, zoom = 0.5 }
  local box = state.layout.b
  return state, graph.screen(state.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
end

test('a click with jitter selects and a drag past the threshold pans instead', function()
  local state, point = fixture()
  local before = state.camera
  view.press(state, point)
  view.move(state, { x = point.x - 4, y = point.y })
  view.release(state, { x = point.x - 4, y = point.y })
  expect.equal(state.selection.id, 'b', 'the clicked instance')
  expect.equal(state.camera, before, 'jitter does not pan')
  view.select(state, { kind = 'node', id = 'a' })
  view.press(state, point)
  view.move(state, { x = point.x + 20, y = point.y })
  view.release(state, { x = point.x + 20, y = point.y + 3 })
  expect.equal(state.selection.id, 'a', 'a drag does not select')
  expect.near(state.camera.x, before.x - 20 / 0.5, 1e-8, 'the drag pans the full displacement')
  expect.near(state.camera.y, before.y - 3 / 0.5, 1e-8, 'release delivers the final move')
end)

test('cancel discards a pending gesture', function()
  local state, point = fixture()
  view.press(state, point)
  view.cancel(state)
  view.release(state, point)
  expect.equal(state.selection, nil, 'a cancelled press cannot select')
  expect.equal(state.dragging, nil)
end)

return test
