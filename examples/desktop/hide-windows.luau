-- A menu action toggles owner-scoped visibility overrides. Disposing this plugin's overrides preserves hidden state owned by other plugins.
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'

export type Config = {}
export type Settings = {}

return plugin.consumer<<Config, Settings>>({
  name = 'hide-windows',
  requires = { menu.capability, panels.capability },
  init = function(context: plugin.Context, _settings: Settings)
    local actions: menu.Service = context:require(menu.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local overrides: { plugin.Effect } = {}
    local hidden = false
    local registration: menu.Registration? = nil
    registration = actions:register(context, {
      id = 'example/hide-windows',
      label = 'Hide windows',
      group = 'Examples',
      order = 1,
      selected = false,
      run = function()
        if not context:active() then
          return
        end
        hidden = not hidden
        if hidden then
          for _, panel in ipairs(panelService:all()) do
            if panel.kind == 'window' and not panel.dead then
              overrides[#overrides + 1] = panel:setHidden(context, true)
            end
          end
        else
          for _, override in ipairs(overrides) do
            override:dispose()
          end
          table.clear(overrides)
        end
        if registration then
          registration:update { selected = hidden }
        end
      end,
    })
  end,
}).definition
