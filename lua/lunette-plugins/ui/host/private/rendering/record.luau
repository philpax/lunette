-- Runs a node's visuals and records the primitives they draw, in node coordinates. The renderer replays the
-- recording every frame until the node's props, state, size, or theme change.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local records = require '../records'

local record = {}

export type Visuals = (name: string) -> { uiHost.Visual }

local TRANSPARENT = table.freeze { 0, 0, 0, 0 }
local WHITE = table.freeze { 1, 1, 1, 1 }

local function newDraw(node: records.Node, primitives: { records.Primitive }): uiHost.Draw
  local draw = {}
  function draw.box(_self: uiHost.Draw, rect: uiHost.Rect?, spec: uiHost.BoxSpec): ()
    local area = rect or node.handle.bounds
    primitives[#primitives + 1] = {
      kind = 'box',
      x = area.x,
      y = area.y,
      width = area.width,
      height = area.height,
      offset = spec.offset or 0,
      depth = spec.depth,
      radius = spec.radius or 0,
      border = spec.border or 0,
      fill = spec.fill or TRANSPARENT,
      borderColor = spec.borderColor or TRANSPARENT,
      side = spec.side,
      edges = spec.edges == true,
      rotation = spec.rotation or 0,
    }
  end
  function draw.text(_self: uiHost.Draw, spec: uiHost.TextSpec): ()
    local lines = node.handle:textLines()
    local style = node.textStyle :: lunette.LayoutTextStyle?
    if not lines or not style or not node.text then
      return
    end
    primitives[#primitives + 1] = {
      kind = 'text',
      lines = lines,
      source = node.text,
      family = style.family or '',
      weight = style.weight or 400,
      x = 0,
      y = 0,
      color = spec.color or node.handle.theme.colors.ink,
      offset = spec.offset or 0,
    }
  end
  function draw.image(_self: uiHost.Draw, rect: uiHost.Rect?, spec: uiHost.ImageSpec): ()
    local area = rect or node.handle.bounds
    primitives[#primitives + 1] = {
      kind = 'image',
      x = area.x,
      y = area.y,
      width = area.width,
      height = area.height,
      source = spec.source,
      tint = spec.tint or WHITE,
      offset = spec.offset or 0,
    }
  end
  return (draw :: any) :: uiHost.Draw
end

-- Records the node's primitives by running its visuals in order. A visual's `base` is the registration it
-- overrides, or nothing for the first registration of a name.
function record.run(node: records.Node, env: records.Environment, visuals: Visuals): { records.Primitive }
  local primitives: { records.Primitive } = {}
  local names = node.kind.registration.visuals
  if not names then
    return primitives
  end
  local draw = newDraw(node, primitives)
  for _, name in names do
    local stack = visuals(name)
    local function call(index: number, handle: uiHost.Node, given: uiHost.Draw): ()
      local visual = stack[index]
      if visual then
        visual(handle, given, function(nextHandle: uiHost.Node, nextDraw: uiHost.Draw): ()
          call(index - 1, nextHandle, nextDraw)
        end)
      end
    end
    local before = #primitives
    local ok = env.protect(`ui: visual {name} of {node.kind.name}`, function(): ()
      call(#stack, node.handle, draw)
    end)
    if not ok then
      -- A failed visual leaves no partial drawing.
      for index = #primitives, before + 1, -1 do
        primitives[index] = nil
      end
    end
  end
  return primitives
end

return record
