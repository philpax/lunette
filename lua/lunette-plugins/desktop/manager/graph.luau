-- Pure layout, dependency queries, and pointer transforms for the projected plugin inspector.

local graph = {}

export type Node = {
  read id: string,
  read name: string,
  read state: string,
  read enabled: boolean,
  read detail: string?,
}

-- Dependency edges point from a consumer to its recorded provider; ownership edges point from a child to its parent.
export type Edge = {
  read id: string,
  read kind: 'dependency' | 'ownership',
  read from: string,
  read to: string,
  read label: string,
  read generation: string?,
}

export type Snapshot = {
  read nodes: { Node },
  read edges: { Edge },
}

export type Point = { read x: number, read y: number }
export type Box = { read x: number, read y: number, read width: number, read height: number }
export type Layout = { read [string]: Box }
export type Camera = { read x: number, read y: number, read zoom: number }
export type Selection = { read kind: 'node', read id: string } | { read kind: 'edge', read id: string }
export type Direction = 'forward' | 'reverse'

local MIN_ZOOM, MAX_ZOOM = 0.2, 4
local NODE_WIDTH, NODE_HEIGHT = 180, 60
local COLUMN_GAP, ROW_GAP = 80, 30

function graph.node(snapshot: Snapshot, id: string): Node?
  for _, node in snapshot.nodes do
    if node.id == id then
      return node
    end
  end
  return nil
end

function graph.edge(snapshot: Snapshot, id: string): Edge?
  for _, edge in snapshot.edges do
    if edge.id == id then
      return edge
    end
  end
  return nil
end

-- Traversal uses recorded bindings only. The origin is excluded even when the graph has a cycle.
function graph.dependencies(snapshot: Snapshot, id: string, direction: Direction, transitive: boolean): { string }
  if not graph.node(snapshot, id) then
    return {}
  end
  local seen: { [string]: boolean } = { [id] = true }
  local queue = { id }
  local result: { string } = {}
  local cursor = 1
  while cursor <= #queue do
    local current = queue[cursor]
    cursor += 1
    for _, edge in snapshot.edges do
      if edge.kind ~= 'dependency' then
        continue
      end
      local source = if direction == 'forward' then edge.from else edge.to
      local target = if direction == 'forward' then edge.to else edge.from
      if source == current and not seen[target] and graph.node(snapshot, target) then
        seen[target] = true
        result[#result + 1] = target
        if transitive then
          queue[#queue + 1] = target
        end
      end
    end
  end
  table.sort(result)
  return result
end

-- Disabling or reloading an instance also unloads its owned children and their bound consumers.
function graph.impact(snapshot: Snapshot, id: string): { string }
  if not graph.node(snapshot, id) then
    return {}
  end
  local seen: { [string]: boolean } = { [id] = true }
  local queue = { id }
  local cursor = 1
  while cursor <= #queue do
    local current = queue[cursor]
    cursor += 1
    for _, edge in snapshot.edges do
      if edge.to == current and not seen[edge.from] and graph.node(snapshot, edge.from) then
        seen[edge.from] = true
        queue[#queue + 1] = edge.from
      end
    end
  end
  table.remove(queue, 1)
  table.sort(queue)
  return queue
end

function graph.search(snapshot: Snapshot, query: string): { string }
  local wanted = string.lower(query)
  local result: { string } = {}
  for _, node in snapshot.nodes do
    local text = string.lower(node.id .. '\n' .. node.name .. '\n' .. node.state .. '\n' .. (node.detail or ''))
    if text:find(wanted, 1, true) then
      result[#result + 1] = node.id
    end
  end
  table.sort(result)
  return result
end

function graph.layout(snapshot: Snapshot): Layout
  local nodes = table.clone(snapshot.nodes)
  table.sort(nodes, function(a: Node, b: Node): boolean
    return if a.name == b.name then a.id < b.id else a.name < b.name
  end)
  local levels: { [string]: number } = {}
  local visiting: { [string]: boolean } = {}
  local function level(id: string): number
    if levels[id] then
      return levels[id]
    end
    if visiting[id] then
      return 0
    end
    visiting[id] = true
    local depth = 0
    for _, edge in snapshot.edges do
      if edge.kind == 'dependency' and edge.from == id and graph.node(snapshot, edge.to) then
        depth = math.max(depth, level(edge.to) + 1)
      end
    end
    visiting[id] = nil
    levels[id] = depth
    return depth
  end
  local rows: { [number]: number } = {}
  local result: { [string]: Box } = {}
  for _, node in nodes do
    local column = level(node.id)
    local row = rows[column] or 0
    rows[column] = row + 1
    result[node.id] = table.freeze {
      x = column * (NODE_WIDTH + COLUMN_GAP),
      y = row * (NODE_HEIGHT + ROW_GAP),
      width = NODE_WIDTH,
      height = NODE_HEIGHT,
    }
  end
  return table.freeze(result)
end

function graph.screen(camera: Camera, world: Point): Point
  return { x = (world.x - camera.x) * camera.zoom, y = (world.y - camera.y) * camera.zoom }
end

function graph.world(camera: Camera, screen: Point): Point
  return { x = screen.x / camera.zoom + camera.x, y = screen.y / camera.zoom + camera.y }
end

function graph.pan(camera: Camera, delta: Point): Camera
  return { x = camera.x - delta.x / camera.zoom, y = camera.y - delta.y / camera.zoom, zoom = camera.zoom }
end

function graph.zoom(camera: Camera, pointer: Point, factor: number): Camera
  local anchor = graph.world(camera, pointer)
  local zoom = math.clamp(camera.zoom * factor, MIN_ZOOM, MAX_ZOOM)
  return { x = anchor.x - pointer.x / zoom, y = anchor.y - pointer.y / zoom, zoom = zoom }
end

function graph.focus(layout: Layout, id: string, viewport: Point, camera: Camera): Camera
  local box = layout[id]
  if not box then
    return camera
  end
  return {
    x = box.x + box.width / 2 - viewport.x / (2 * camera.zoom),
    y = box.y + box.height / 2 - viewport.y / (2 * camera.zoom),
    zoom = camera.zoom,
  }
end

-- Fit centers the full bounds; graphs larger than the minimum scale permits remain pannable.
function graph.fit(layout: Layout, viewport: Point): Camera
  local right, bottom = 0, 0
  for _, box in layout do
    right = math.max(right, box.x + box.width)
    bottom = math.max(bottom, box.y + box.height)
  end
  if right == 0 or bottom == 0 then
    return { x = 0, y = 0, zoom = 1 }
  end
  local zoom = math.clamp(math.min(viewport.x / (right + 40), viewport.y / (bottom + 40)), MIN_ZOOM, MAX_ZOOM)
  return { x = right / 2 - viewport.x / (2 * zoom), y = bottom / 2 - viewport.y / (2 * zoom), zoom = zoom }
end

function graph.endpoints(layout: Layout, edge: Edge): (Point?, Point?)
  local from, to = layout[edge.from], layout[edge.to]
  if not from or not to then
    return nil, nil
  end
  return { x = from.x + from.width / 2, y = from.y + from.height / 2 }, {
    x = to.x + to.width / 2,
    y = to.y + to.height / 2,
  }
end

-- Parallel relationships use distinct bends separated in screen pixels, shared by rendering and hit testing.
function graph.route(snapshot: Snapshot, layout: Layout, camera: Camera, edge: Edge): { Point }
  local from, to = graph.endpoints(layout, edge)
  if not from or not to then
    return {}
  end
  local peers: { string } = {}
  for _, candidate in snapshot.edges do
    if
      (candidate.from == edge.from and candidate.to == edge.to)
      or (candidate.from == edge.to and candidate.to == edge.from)
    then
      peers[#peers + 1] = candidate.id
    end
  end
  table.sort(peers)
  local ordinal = table.find(peers, edge.id) or 1
  if edge.from == edge.to then
    local box = layout[edge.from]
    local extent = (20 + 20 * ordinal) / camera.zoom
    return {
      { x = box.x + box.width, y = box.y + box.height / 2 },
      { x = box.x + box.width + extent, y = box.y + box.height / 2 },
      { x = box.x + box.width + extent, y = box.y - extent },
      { x = box.x + box.width / 2, y = box.y - extent },
      { x = box.x + box.width / 2, y = box.y },
    }
  end
  local offset = (ordinal - (#peers + 1) / 2) * 20 / camera.zoom
  local dx, dy = to.x - from.x, to.y - from.y
  if edge.from > edge.to then
    dx, dy = -dx, -dy
  end
  local length = math.sqrt(dx * dx + dy * dy)
  local nx, ny = if length == 0 then 0 else -dy / length, if length == 0 then 1 else dx / length
  local midpoint = { x = (from.x + to.x) / 2 + nx * offset, y = (from.y + to.y) / 2 + ny * offset }
  return { from, midpoint, to }
end

local function distance(point: Point, from: Point, to: Point): number
  local dx, dy = to.x - from.x, to.y - from.y
  local length = dx * dx + dy * dy
  local t = if length == 0 then 0 else math.clamp(((point.x - from.x) * dx + (point.y - from.y) * dy) / length, 0, 1)
  local x, y = from.x + t * dx - point.x, from.y + t * dy - point.y
  return math.sqrt(x * x + y * y)
end

-- Node rectangles take precedence over edges; the edge tolerance remains constant in screen pixels.
function graph.hit(snapshot: Snapshot, layout: Layout, camera: Camera, pointer: Point): Selection?
  local world = graph.world(camera, pointer)
  for _, node in snapshot.nodes do
    local box = layout[node.id]
    if
      box
      and world.x >= box.x
      and world.x <= box.x + box.width
      and world.y >= box.y
      and world.y <= box.y + box.height
    then
      return { kind = 'node', id = node.id }
    end
  end
  local closest: Selection? = nil
  local best = 7
  for _, edge in snapshot.edges do
    local route = graph.route(snapshot, layout, camera, edge)
    for index = 1, #route - 1 do
      local separation = distance(pointer, graph.screen(camera, route[index]), graph.screen(camera, route[index + 1]))
      if separation < best or (separation == best and closest and edge.id < closest.id) then
        best = separation
        local selected: Selection = { kind = 'edge', id = edge.id }
        closest = selected
      end
    end
  end
  return closest
end

return graph
