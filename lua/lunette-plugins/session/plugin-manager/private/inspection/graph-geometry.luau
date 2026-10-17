-- Projects graph nodes, routes, and arrowheads into canvas pixels, clipped to the canvas, for the graph kinds.
local graph = require './graph'
local view = require './view'

local geometry = {}

export type Node = { read node: graph.Node, read bounds: graph.Box, read clipped: graph.Box? }
export type Edge = { read edge: graph.Edge, read points: { read [number]: graph.Point } }
export type Scene = {
  read nodes: { read [number]: Node },
  read edges: { read [number]: Edge },
}
export type Role = 'selected' | 'dependency' | 'ownership'
-- A clipped straight piece of an edge or of its arrowhead, in canvas pixels.
export type Segment = {
  read x1: number,
  read y1: number,
  read x2: number,
  read y2: number,
  read role: Role,
}

local ARROW_PIXELS = 8

function geometry.intersect(box: graph.Box, clip: graph.Box): graph.Box?
  local x, y = math.max(box.x, clip.x), math.max(box.y, clip.y)
  local right = math.min(box.x + box.width, clip.x + clip.width)
  local bottom = math.min(box.y + box.height, clip.y + clip.height)
  return if right > x and bottom > y then { x = x, y = y, width = right - x, height = bottom - y } else nil
end

-- Liang-Barsky clipping of a segment to a box.
function geometry.segment(from: graph.Point, to: graph.Point, clip: graph.Box): (graph.Point?, graph.Point?)
  local dx, dy = to.x - from.x, to.y - from.y
  local first, last = 0, 1
  local p = { -dx, dx, -dy, dy }
  local q = { from.x - clip.x, clip.x + clip.width - from.x, from.y - clip.y, clip.y + clip.height - from.y }
  for index = 1, 4 do
    if p[index] == 0 then
      if q[index] < 0 then
        return nil, nil
      end
    elseif p[index] < 0 then
      first = math.max(first, q[index] / p[index])
    else
      last = math.min(last, q[index] / p[index])
    end
  end
  if last < first or clip.width <= 0 or clip.height <= 0 then
    return nil, nil
  end
  return { x = from.x + first * dx, y = from.y + first * dy }, { x = from.x + last * dx, y = from.y + last * dy }
end

-- The visible nodes and edges of the view, with screen positions offset by the canvas origin.
function geometry.project(state: view.State, bounds: graph.Box): Scene
  local visible = view.visible(state)
  local nodes: { Node } = {}
  local edges: { Edge } = {}
  for _, edge in state.snapshot.edges do
    if not visible[edge.from] or not visible[edge.to] then
      continue
    end
    local points: { graph.Point } = {}
    for _, point in graph.route(state.snapshot, state.layout, state.camera, edge) do
      local screen = graph.screen(state.camera, point)
      points[#points + 1] = table.freeze { x = screen.x + bounds.x, y = screen.y + bounds.y }
    end
    edges[#edges + 1] = table.freeze { edge = edge, points = table.freeze(points) }
  end
  for _, node in state.snapshot.nodes do
    local box = state.layout[node.id]
    if not visible[node.id] or not box then
      continue
    end
    local origin = graph.screen(state.camera, { x = box.x, y = box.y })
    local pixels = table.freeze {
      x = origin.x + bounds.x,
      y = origin.y + bounds.y,
      width = box.width * state.camera.zoom,
      height = box.height * state.camera.zoom,
    }
    nodes[#nodes + 1] = table.freeze { node = node, bounds = pixels, clipped = geometry.intersect(pixels, bounds) }
  end
  return table.freeze { nodes = table.freeze(nodes), edges = table.freeze(edges) }
end

-- The clipped line pieces of every projected edge, with an arrowhead where the edge meets its target's box.
function geometry.lines(state: view.State, scene: Scene, clip: graph.Box): { Segment }
  local result: { Segment } = {}
  local selection = state.selection
  local function add(from: graph.Point, to: graph.Point, role: Role): ()
    local first, last = geometry.segment(from, to, clip)
    if first and last then
      result[#result + 1] = table.freeze { x1 = first.x, y1 = first.y, x2 = last.x, y2 = last.y, role = role }
    end
  end
  for _, projected in scene.edges do
    local edge, points = projected.edge, projected.points
    local role: Role = if selection
        and selection.kind == 'edge'
        and selection.id == edge.id
      then 'selected'
      else edge.kind
    for index = 1, #points - 1 do
      add(points[index], points[index + 1], role)
    end
    if #points < 2 then
      continue
    end
    local from, target = points[#points - 1], points[#points]
    local dx, dy = target.x - from.x, target.y - from.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length == 0 then
      continue
    end
    local ux, uy = dx / length, dy / length
    local inset = 0
    local box = state.layout[edge.to]
    if box and edge.from ~= edge.to then
      inset = math.min(
        if ux == 0 then math.huge else box.width * state.camera.zoom / (2 * math.abs(ux)),
        if uy == 0 then math.huge else box.height * state.camera.zoom / (2 * math.abs(uy))
      )
    end
    local tip: graph.Point = { x = target.x - ux * inset, y = target.y - uy * inset }
    local size = math.min(ARROW_PIXELS, math.max(0, length - inset))
    add(tip, { x = tip.x - ux * size - uy * size / 2, y = tip.y - uy * size + ux * size / 2 }, role)
    add(tip, { x = tip.x - ux * size + uy * size / 2, y = tip.y - uy * size - ux * size / 2 }, role)
  end
  return result
end

return geometry
