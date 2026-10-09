-- Stateful input for the inspector canvas; rendering and runtime mutations remain outside this module.

local graph = require './graph'
local view = {}

export type Mode = 'all' | 'providers' | 'consumers' | 'impact'
type Gesture =
  { kind: 'pending-click', press: graph.Point }
  | {
    kind: 'dragging',
    press: graph.Point,
    previous: graph.Point,
  }
export type State = {
  snapshot: graph.Snapshot,
  layout: graph.Layout,
  camera: graph.Camera,
  viewport: graph.Point,
  selection: graph.Selection?,
  query: string,
  searchActive: boolean,
  mode: Mode,
  transitive: boolean,
  dragging: Gesture?,
}

local DRAG_THRESHOLD_PIXELS = 5

function view.new(viewport: graph.Point): State
  return {
    snapshot = { nodes = {}, edges = {} },
    layout = {},
    camera = { x = 0, y = 0, zoom = 1 },
    viewport = viewport,
    selection = nil,
    query = '',
    searchActive = false,
    mode = 'all',
    transitive = false,
    dragging = nil,
  }
end

function view.update(state: State, snapshot: graph.Snapshot): ()
  local first = #state.snapshot.nodes == 0
  state.snapshot = snapshot
  state.layout = graph.layout(snapshot)
  local selection = state.selection
  if selection then
    local present = if selection.kind == 'node'
      then graph.node(snapshot, selection.id) ~= nil
      else graph.edge(snapshot, selection.id) ~= nil
    if not present then
      state.selection = nil
    end
  end
  if first then
    state.camera = graph.fit(state.layout, state.viewport)
  end
end

function view.visible(state: State): { [string]: boolean }
  local matching: { [string]: boolean } = {}
  for _, id in graph.search(state.snapshot, state.query) do
    matching[id] = true
  end
  local selection = state.selection
  if not selection or selection.kind ~= 'node' or state.mode == 'all' then
    return matching
  end
  local related = if state.mode == 'impact'
    then graph.impact(state.snapshot, selection.id)
    else graph.dependencies(
      state.snapshot,
      selection.id,
      if state.mode == 'providers' then 'forward' else 'reverse',
      state.transitive
    )
  local result: { [string]: boolean } = {}
  result[selection.id] = matching[selection.id] == true
  for _, id in related do
    if matching[id] then
      result[id] = true
    end
  end
  return result
end

function view.select(state: State, selection: graph.Selection?): ()
  state.selection = selection
end

function view.press(state: State, point: graph.Point): ()
  state.dragging = { kind = 'pending-click', press = { x = point.x, y = point.y } }
end

function view.move(state: State, point: graph.Point): ()
  local gesture = state.dragging
  if not gesture then
    return
  end
  local previous: graph.Point
  if gesture.kind == 'pending-click' then
    previous = gesture.press
    local dx, dy = point.x - previous.x, point.y - previous.y
    if dx * dx + dy * dy <= DRAG_THRESHOLD_PIXELS * DRAG_THRESHOLD_PIXELS then
      return
    end
  else
    previous = gesture.previous
  end
  local delta = { x = point.x - previous.x, y = point.y - previous.y }
  if delta.x ~= 0 or delta.y ~= 0 then
    state.camera = graph.pan(state.camera, delta)
  end
  state.dragging = { kind = 'dragging', press = gesture.press, previous = { x = point.x, y = point.y } }
end

function view.release(state: State, point: graph.Point): ()
  view.move(state, point)
  local gesture = state.dragging
  if gesture and gesture.kind == 'pending-click' then
    local visible = view.visible(state)
    local nodes: { graph.Node } = {}
    local edges: { graph.Edge } = {}
    for _, node in state.snapshot.nodes do
      if visible[node.id] then
        nodes[#nodes + 1] = node
      end
    end
    for _, edge in state.snapshot.edges do
      if visible[edge.from] and visible[edge.to] then
        edges[#edges + 1] = edge
      end
    end
    state.selection = graph.hit({ nodes = nodes, edges = edges }, state.layout, state.camera, gesture.press)
  end
  state.dragging = nil
end

function view.cancel(state: State): ()
  state.dragging = nil
end

function view.zoom(state: State, point: graph.Point, factor: number): ()
  state.camera = graph.zoom(state.camera, point, factor)
end

function view.reset(state: State): ()
  state.query = ''
  state.mode = 'all'
  state.searchActive = false
  state.camera = graph.fit(state.layout, state.viewport)
end

function view.focus(state: State): ()
  local selection = state.selection
  if selection and selection.kind == 'node' then
    state.camera = graph.focus(state.layout, selection.id, state.viewport, state.camera)
  end
end

function view.search(state: State): ()
  state.searchActive = true
end

function view.setSearch(state: State, value: string): ()
  state.query = value
end

function view.endSearch(state: State): ()
  state.searchActive = false
end

return view
