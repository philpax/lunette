-- Shows the configured hint on a UI host panel while no window or monitor panel exists. The panel is part of the
-- scene rather than a window panel, so showing it does not count as a panel being present.
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'

local config = require '@self/config'

export type Config = config.Config
export type Settings = config.Settings

local PANEL = 'desktop/hint'
-- The widest the hint grows before its text wraps, in metres.
local MAX_WIDTH = 0.6

local required: plugin.Declaration = {
  panels.capability,
  uiHost.capability,
  uiComponents.capability,
}

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/hint',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local panelService: panels.Service = context:require(panels.capability)
    local host: uiHost.Service = context:require(uiHost.capability)
    local components: uiComponents.Service = context:require(uiComponents.capability)
    local panel = host:newPanel(context, {
      name = PANEL,
      pose = lovr.math.newMat4():translate(settings.position),
      width = MAX_WIDTH,
      height = MAX_WIDTH,
      size = 'content',
      grabbable = false,
      visible = false,
    })
    panel.root:bind {
      render = function(): ()
        panel.root:submit(components.Panel {
          padding = 'lg',
          components.Text {
            key = 'text',
            text = settings.text,
            style = 'title',
            color = settings.foreground,
            align = 'center',
          },
        })
      end,
    }
    -- Even a hidden panel suppresses the hint. A removed listener runs after the panel has left the list.
    local function refresh(): ()
      if context:active() and not panel.dead then
        panel:setVisible(#panelService:all() == 0)
      end
    end
    panelService:onAdded(context, {
      run = function(_panel: panels.Panel): ()
        if context:active() and not panel.dead then
          panel:setVisible(false)
        end
      end,
    })
    panelService:onRemoved(context, {
      run = function(_panel: panels.Panel): ()
        refresh()
      end,
    })
    refresh()
  end,
}
