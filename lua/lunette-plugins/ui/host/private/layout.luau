-- Applies a commit's layout changes to the panel's native tree, computes layout, and places nodes.
-- Each panel has a host root, node 0, which holds the content root and carries the panel's fixed size.

local lunette = require '@lunette'
local records = require './records'
local handles = require './handles'

local layout = {}

layout.ROOT = 0

local PLACEMENT_STRIDE = 7

-- The host root's style: the content root fills a fixed panel and sizes a content-sized one.
function layout.rootStyle(panel: records.Panel): lunette.LayoutStyle
  if panel.sizing == 'fixed' then
    return { flexDirection = 'column', alignItems = 'stretch', width = panel.width, height = panel.height }
  end
  return { flexDirection = 'column', alignItems = 'start', maxWidth = panel.maxWidth, maxHeight = panel.maxHeight }
end

function layout.newTree(panel: records.Panel): lunette.LayoutTree
  local created = lunette.newLayoutTree()
  created:apply { { op = 'create', id = layout.ROOT, kind = 'box', style = layout.rootStyle(panel) } }
  return created
end

-- A rejected batch is retried change by change, so one invalid style cannot stall the panel. A create that is
-- rejected is retried with the default style, which keeps the native tree in step with the node records.
local function apply(panel: records.Panel, env: records.Environment, changes: { lunette.LayoutChange }): ()
  local ok, failure = pcall(panel.tree.apply, panel.tree, changes)
  if ok then
    return
  end
  local reported = false
  for _, change in changes do
    local applied = pcall(panel.tree.apply, panel.tree, { change })
    if not applied then
      if not reported then
        reported = true
        env.protect(`ui: panel '{panel.name}' layout`, function(): ()
          error(failure, 0)
        end)
      end
      if change.op == 'create' then
        panel.tree:apply { { op = 'create', id = change.id, kind = change.kind, text = change.text } }
      elseif change.op == 'text' then
        pcall(panel.tree.apply, panel.tree, { { op = 'text', id = change.id, text = change.text } })
      end
    end
  end
end

-- Applies pending changes and recomputes layout, answering whether any placement changed.
function layout.commit(panel: records.Panel, env: records.Environment): boolean
  local changes = panel.changes
  panel.changes = {}
  local root = panel.root
  local wanted = if root then { root.id } else {}
  if root and panel.rootChild ~= root.id or not root and panel.rootChild ~= nil then
    local change: lunette.LayoutChange = { op = 'children', id = layout.ROOT, children = wanted }
    changes[#changes + 1] = change
    panel.rootChild = if root then root.id else nil
  end
  -- A fixed panel whose size changed, such as one attached to a window that was resized, restyles its host root.
  if panel.sizing == 'fixed' then
    local size = panel.rootSize
    if size == nil or size[1] ~= panel.width or size[2] ~= panel.height then
      panel.rootSize = { panel.width, panel.height }
      local change: lunette.LayoutChange = { op = 'style', id = layout.ROOT, style = layout.rootStyle(panel) }
      changes[#changes + 1] = change
    end
  end
  if #changes > 0 then
    apply(panel, env, changes)
  end
  local width = if panel.sizing == 'content' then panel.maxWidth else nil
  local height = if panel.sizing == 'content' then panel.maxHeight else nil
  local flat, failures = panel.tree:compute(layout.ROOT, width, height)
  for _, failure in failures do
    env.protect(`ui: panel '{panel.name}' layout of node {failure.id}`, function(): ()
      error(failure.message, 0)
    end)
  end
  local changed = false
  for index = 1, #flat, PLACEMENT_STRIDE do
    local id = flat[index]
    local u, v, w, h = flat[index + 1], flat[index + 2], flat[index + 3], flat[index + 4]
    if id == layout.ROOT then
      if panel.sizing == 'content' and (w ~= panel.width or h ~= panel.height) then
        panel.width, panel.height = w, h
        panel.revision += 1
      end
    else
      local node = panel.nodes[id]
      if node then
        if node.width ~= w or node.height ~= h then
          node.primitives = nil
        end
        node.u, node.v, node.width, node.height = u, v, w, h
        handles.refreshBounds(node)
      end
    end
    changed = true
  end
  return changed
end

-- Each nesting level stands this far in front of its parent, so a child's fill never shares its parent's depth. The
-- primitives of one node step by less, so a node's whole drawing stays below its children's.
local NEST_STEP = 0.0001

-- Positions every node in panel coordinates for this frame: layout less ancestor scroll, and surface height from
-- elevation, the animated lift, and the nesting step.
function layout.place(panel: records.Panel): ()
  local function visit(node: records.Node, scrollX: number, scrollY: number, surface: number): ()
    node.x, node.y = node.u - scrollX, node.v - scrollY
    node.z = surface
      + node.elevation
      + node.lift
      + (if node.parent and node.parent.panel == panel then NEST_STEP else 0)
    local childScrollX, childScrollY = scrollX, scrollY
    if node.kind.registration.clip then
      -- The offset is clamped to the content, so content that shrinks does not leave the box scrolled past its end.
      local contentWidth, contentHeight = 0, 0
      for _, child in node.children do
        contentWidth = math.max(contentWidth, child.u + child.width - node.u)
        contentHeight = math.max(contentHeight, child.v + child.height - node.v)
      end
      childScrollX += math.clamp(node.state.scrollX or 0, 0, math.max(contentWidth - node.width, 0))
      childScrollY += math.clamp(node.state.scrollY or 0, 0, math.max(contentHeight - node.height, 0))
    end
    for _, child in node.children do
      visit(child, childScrollX, childScrollY, node.z)
    end
  end
  if panel.root then
    visit(panel.root, 0, 0, 0)
  end
end

return layout
