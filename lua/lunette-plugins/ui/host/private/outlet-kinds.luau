-- The host's primitive kinds for outlets: the outlet node, the plain slot around an unattributed contribution, and
-- the attribution frame, its label, and its clipping body around an attributed one, with the frame's base visuals.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'

local outletKinds = {}

outletKinds.OUTLET = 'lunette/outlet'
outletKinds.SLOT = 'lunette/outlet-slot'
outletKinds.FRAME = 'lunette/outlet-frame'
outletKinds.LABEL = 'lunette/outlet-label'
outletKinds.BODY = 'lunette/outlet-body'

local function kind(owner: plugin.Owner, registration: uiHost.KindRegistration, isOutlet: boolean): records.Kind
  return {
    name = registration.name,
    owner = owner,
    registration = registration,
    composite = false,
    portal = false,
    outlet = isOutlet,
  }
end

local function column(gap: number?): lunette.LayoutStyle
  return { flexDirection = 'column', alignItems = 'stretch', gap = gap }
end

function outletKinds.kinds(owner: plugin.Owner): { records.Kind }
  return {
    kind(owner, {
      name = outletKinds.OUTLET,
      layout = {
        kind = 'container',
        style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
          return column(theme.spacing.sm)
        end,
      },
    }, true),
    kind(owner, {
      name = outletKinds.SLOT,
      layout = {
        kind = 'container',
        style = function(): lunette.LayoutStyle
          return column()
        end,
      },
    }, false),
    -- The frame takes the outlet's width and at most its maximum height, and clips what the contribution draws
    -- beyond them, so a contribution cannot push the rest of the panel out of view.
    kind(owner, {
      name = outletKinds.FRAME,
      layout = {
        kind = 'container',
        style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
          return {
            flexDirection = 'column',
            alignItems = 'stretch',
            gap = theme.spacing.xs,
            padding = theme.spacing.sm,
            maxHeight = props.maxHeight,
            minWidth = 0,
            overflow = 'clip',
          }
        end,
      },
      clip = true,
      visuals = { outletKinds.FRAME },
    }, false),
    kind(owner, {
      name = outletKinds.LABEL,
      layout = {
        kind = 'text',
        text = function(props: uiHost.Props): string
          return props.text
        end,
        textStyle = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutTextStyle
          local caption = theme.type.caption
          return {
            family = caption.family,
            size = caption.size,
            weight = caption.weight,
            lineHeight = caption.lineHeight,
            wrap = 'none',
          }
        end,
      },
      visuals = { outletKinds.LABEL },
    }, false),
    kind(owner, {
      name = outletKinds.BODY,
      layout = {
        kind = 'container',
        style = function(): lunette.LayoutStyle
          return {
            flexDirection = 'column',
            alignItems = 'stretch',
            shrink = 1,
            minHeight = 0,
            minWidth = 0,
            overflow = 'clip',
          }
        end,
      },
      clip = true,
    }, false),
  }
end

function outletKinds.visuals(): { [string]: uiHost.Visual }
  return {
    [outletKinds.FRAME] = function(node: uiHost.Node, draw: uiHost.Draw): ()
      local theme = node.theme
      draw:box(nil, {
        fill = theme.colors.sunken,
        border = theme.sizes.rule,
        borderColor = theme.colors.line,
        radius = theme.radii.control,
      })
    end,
    [outletKinds.LABEL] = function(node: uiHost.Node, draw: uiHost.Draw): ()
      draw:text { color = node.theme.colors.muted }
    end,
  }
end

return outletKinds
