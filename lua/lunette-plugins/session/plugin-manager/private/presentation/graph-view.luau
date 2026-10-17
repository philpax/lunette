-- The dependency graph: the canvas kind with node cards and edge labels positioned from the shared graph geometry.
-- The graph lays out in pixels, and the canvas shows each pixel at a fixed length.

local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local controller = require '../composition/controller'
local graph = require '../inspection/graph'
local geometry = require '../inspection/graph-geometry'
local model = require './model'

local graphView = {}

-- Metres per graph pixel at zoom 1.
graphView.PIXEL = 0.0006
local PIXEL = graphView.PIXEL
local LABEL_OFFSET = 5
local LABEL_WIDTH = 180
-- Zoom factor per unit of scroll; positive scroll zooms in.
local SCROLL_ZOOM = 0.1

local function status(node: graph.Node): string
  if node.state == 'failed' or node.state == 'quarantined' then
    return 'danger'
  elseif not node.enabled or node.state == 'inactive' or node.state == 'removed' then
    return 'muted'
  elseif node.state == 'blocked' or node.state == 'loading' or node.state == 'unloading' then
    return 'warning'
  elseif node.state == 'active' then
    return 'success'
  end
  return 'ink'
end

-- The message shown under the canvas when the graph is empty, filtered out, or partly off the canvas.
function graphView.message(state: controller.State, scene: geometry.Scene): string
  if #state.view.snapshot.nodes == 0 then
    return 'No plugins in the graph.'
  elseif #scene.nodes == 0 then
    return 'No plugins match the current filter.'
  end
  local outside = 0
  for _, node in scene.nodes do
    if not node.clipped then
      outside += 1
    end
  end
  return if outside > 0 then `{outside} plugins outside the canvas. Pan or fit the graph.` else ''
end

graphView.Graph = ui.component('PluginGraph', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local kinds = m.kinds
  local viewport = state.view.viewport
  local bounds = { x = 0, y = 0, width = viewport.x, height = viewport.y }
  local scene = geometry.project(state.view, bounds)
  local selection = state.view.selection
  local lines = {}
  for index, segment in geometry.lines(state.view, scene, bounds) do
    lines[index] = {
      x1 = segment.x1 * PIXEL,
      y1 = segment.y1 * PIXEL,
      x2 = segment.x2 * PIXEL,
      y2 = segment.y2 * PIXEL,
      role = segment.role,
    }
  end
  local children = {}
  for _, projected in scene.edges do
    local edge, points = projected.edge, projected.points
    local middle = points[math.ceil(#points / 2)]
    if
      #points < 2
      or not middle
      or not geometry.intersect({ x = middle.x, y = middle.y, width = 1, height = 1 }, bounds)
    then
      continue
    end
    local selected = selection ~= nil and selection.kind == 'edge' and selection.id == edge.id
    children[#children + 1] = kinds.Label {
      key = 'edge-' .. uiHost.keyOf(edge.id),
      left = (middle.x + LABEL_OFFSET) * PIXEL,
      top = (middle.y + LABEL_OFFSET) * PIXEL,
      maxWidth = LABEL_WIDTH * PIXEL,
      selected = selected,
      onActivate = function(): ()
        m.change(function(): ()
          controller.select(state, { kind = 'edge', id = edge.id })
        end)
      end,
      c.Text {
        key = 'text',
        text = edge.label .. (if edge.generation then ' [' .. edge.generation .. ']' else ''),
        style = 'caption',
        color = if selected then 'accentInk' else 'muted',
        wrap = false,
        maxLines = 1,
      },
    }
  end
  for _, projected in scene.nodes do
    if not projected.clipped then
      continue
    end
    local node, box = projected.node, projected.bounds
    children[#children + 1] = kinds.Node {
      key = 'node-' .. uiHost.keyOf(node.id),
      left = box.x * PIXEL,
      top = box.y * PIXEL,
      width = box.width * PIXEL,
      height = box.height * PIXEL,
      status = status(node),
      selected = selection ~= nil and selection.kind == 'node' and selection.id == node.id,
      onActivate = function(): ()
        m.change(function(): ()
          controller.select(state, { kind = 'node', id = node.id })
        end)
      end,
      c.Text { key = 'name', text = node.name, style = 'label', wrap = false, maxLines = 1 },
      c.Text {
        key = 'state',
        text = node.state .. (if node.enabled then '' else ' (disabled)'),
        style = 'caption',
        color = 'muted',
        wrap = false,
        maxLines = 1,
      },
    }
  end
  local message = graphView.message(state, scene)
  local function point(x: number, y: number): graph.Point
    return { x = x / PIXEL, y = y / PIXEL }
  end
  return c.Column {
    key = 'graph',
    grow = 1,
    height = 0,
    gap = 'xs',
    kinds.Canvas {
      key = 'canvas',
      ref = m.canvas,
      lines = lines,
      onPress = function(x: number, y: number): ()
        controller.graphPress(state, point(x, y))
      end,
      onDrag = function(x: number, y: number): ()
        m.change(function(): ()
          controller.graphMove(state, point(x, y))
        end)
      end,
      onRelease = function(x: number, y: number, inside: boolean): ()
        m.change(function(): ()
          controller.graphRelease(state, point(x, y), inside)
        end)
      end,
      onCancel = function(): ()
        m.change(function(): ()
          controller.graphCancel(state)
        end)
      end,
      onScroll = function(dy: number, x: number, y: number): ()
        m.change(function(): ()
          controller.graphZoom(state, math.exp(dy * SCROLL_ZOOM), point(x, y))
        end)
      end,
      children,
    },
    if message ~= ''
      then c.Text { key = 'message', text = message, style = 'caption', color = 'muted', maxLines = 2 }
      else nil,
  }
end)

return graphView
