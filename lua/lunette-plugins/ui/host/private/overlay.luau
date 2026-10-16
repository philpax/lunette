-- Overlay panels: the panels that portals render into, positioned against the opener node in the opener's panel.
-- An overlay opens below its anchor, flips above it when the opener's panel has no room below, and stands one
-- popover step above the anchor's surface.

local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'
local tree = require './tree'
local panel = require './panel'

local overlay = {}

local GAP = 0.002

-- The node an overlay is positioned against: the portal's parent, or the portal itself at the root.
function overlay.anchor(portal: records.Node): records.Node
  return portal.parent or portal
end

-- Opens the portal's overlay panel, or updates its content.
function overlay.render(provider: panel.Provider, portal: records.Node): records.Panel
  local opener = portal.panel
  local record = portal.overlay
  if not record then
    local created = panel.record(`{opener.name}/{portal.slot}`, opener.owner, 'content', nil, nil, opener.pose)
    created.overlay = { portal = portal, opener = opener, hit = portal.props.hit ~= false }
    portal.overlay = created
    record = created
    provider.offer(created, panel.surface(provider, created, nil))
  end
  local current = assert(record)
  local anchor = overlay.anchor(portal)
  local wrapper = uiHost.element('lunette/overlay-root', {
    minWidth = if portal.props.matchWidth then anchor.width else nil,
    portal.element.children,
  })
  current.mount.rendering = true
  tree.submit(current, provider.env, wrapper, portal)
  current.mount.rendering = false
  return current
end

function overlay.close(provider: panel.Provider, portal: records.Node): ()
  local record = portal.overlay
  if record then
    portal.overlay = nil
    panel.destroy(provider, record)
  end
end

-- Poses the overlay against its anchor, after the opener's and the overlay's layout for this frame.
function overlay.place(provider: panel.Provider, record: records.Panel): ()
  local relation = record.overlay
  if not relation then
    return
  end
  local opener = relation.opener
  local anchor = overlay.anchor(relation.portal)
  -- A width matched to the anchor is known only after the opener's layout, so the overlay renders again when it
  -- changes, and lays out in the next commit.
  local root = record.root
  if relation.portal.props.matchWidth and root and root.props.minWidth ~= anchor.width then
    overlay.render(provider, relation.portal)
  end
  local theme = anchor.handle.theme
  local width, height = record.width, record.height
  local left = anchor.x
  local below = anchor.y + anchor.height + GAP
  local above = anchor.y - GAP - height
  local placement = relation.portal.props.placement or 'below'
  local top = below
  if placement == 'above' or (below + height > opener.height and above >= 0) then
    top = above
  end
  if placement == 'right' then
    left, top = anchor.x + anchor.width + GAP, anchor.y
  end
  -- Overlays stay within the opener's width where they fit, sliding along the edge rather than overhanging it.
  if left + width > opener.width and width <= opener.width then
    left = opener.width - width
  end
  local elevation = anchor.z + theme.elevation.raised
  local x = left + width / 2 - opener.width / 2
  local y = opener.height / 2 - (top + height / 2)
  record.pose:set(opener.pose):translate(x, y, elevation)
  record.visible = opener.visible
  record.sync()
end

-- Whether a press on a panel at a node belongs to the overlay's chain: the overlay itself, an overlay opened from
-- it, or the anchor that opened it.
function overlay.contains(record: records.Panel, pressed: records.Panel, node: records.Node?): boolean
  local current: records.Panel? = pressed
  while current do
    if current == record then
      return true
    end
    local relation = current.overlay
    current = if relation then relation.opener else nil
  end
  local relation = record.overlay
  if relation == nil or pressed ~= relation.opener then
    return false
  end
  local anchor = overlay.anchor(relation.portal)
  local walk: records.Node? = node
  while walk do
    if walk == anchor then
      return true
    end
    walk = walk.parent
  end
  return false
end

return overlay
