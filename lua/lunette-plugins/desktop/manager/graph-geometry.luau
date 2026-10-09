-- Projects graph nodes and routes once for both panel drawing and public inspection.
local ui = require '@lunette-contracts/ui'
local graph = require './graph'
local view = require './view'

local geometry = {}

export type Node = { read node: graph.Node, read bounds: graph.Box, read clipped: graph.Box? }
export type Edge = { read edge: graph.Edge, read points: { read [number]: graph.Point } }
export type Scene = {
  read nodes: { read [number]: Node },
  read edges: { read [number]: Edge },
  read items: { read [number]: ui.RegionItem },
}

function geometry.intersect(box: graph.Box, clip: graph.Box): graph.Box?
  local x, y = math.max(box.x, clip.x), math.max(box.y, clip.y)
  local right = math.min(box.x + box.width, clip.x + clip.width)
  local bottom = math.min(box.y + box.height, clip.y + clip.height)
  return if right > x and bottom > y then { x = x, y = y, width = right - x, height = bottom - y } else nil
end

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

function geometry.project(state: view.State, bounds: graph.Box, contentClip: graph.Box?): Scene
  local clip = contentClip or bounds
  local visible = view.visible(state)
  local nodes: { Node } = {}
  local edges: { Edge } = {}
  local items: { ui.RegionItem } = {}
  for _, edge in state.snapshot.edges do
    if not visible[edge.from] or not visible[edge.to] then
      continue
    end
    local points: { graph.Point } = {}
    local route: { graph.Point } = {}
    for _, point in graph.route(state.snapshot, state.layout, state.camera, edge) do
      local screen = graph.screen(state.camera, point)
      points[#points + 1] = table.freeze { x = screen.x + bounds.x, y = screen.y + bounds.y }
    end
    for index = 1, #points - 1 do
      local first, last = geometry.segment(points[index], points[index + 1], clip)
      if first and last then
        local previous = route[#route]
        if not previous or previous.x ~= first.x or previous.y ~= first.y then
          route[#route + 1] = table.freeze(first)
        end
        route[#route + 1] = table.freeze(last)
      end
    end
    edges[#edges + 1] = table.freeze { edge = edge, points = table.freeze(points) }
    if #route > 1 then
      local left: number = math.huge
      local top: number = math.huge
      local right: number = -math.huge
      local bottom: number = -math.huge
      for _, point in route do
        left = math.min(left, point.x)
        top = math.min(top, point.y)
        right = math.max(right, point.x)
        bottom = math.max(bottom, point.y)
      end
      items[#items + 1] = table.freeze {
        id = 'edge/' .. edge.id,
        label = edge.label,
        bounds = table.freeze {
          x = left,
          y = top,
          width = math.max(0.001, right - left),
          height = math.max(0.001, bottom - top),
        },
        route = points,
      }
    end
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
    local clipped = geometry.intersect(pixels, clip)
    nodes[#nodes + 1] = table.freeze { node = node, bounds = pixels, clipped = clipped }
    if clipped then
      items[#items + 1] = table.freeze {
        id = 'node/' .. node.id,
        label = node.name,
        bounds = table.freeze(clipped),
      }
    end
  end
  return table.freeze { nodes = table.freeze(nodes), edges = table.freeze(edges), items = table.freeze(items) }
end

return geometry
