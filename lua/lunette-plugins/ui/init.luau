-- Publishes replaceable owner-scoped VR panels without installing a frame drawing order.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local panel = require '@lunette-plugins/ui/panel'
local config = require '@lunette-plugins/ui/config'
local owners = require '@lunette-plugins/ui/control-owners'
local validation = require '@lunette-plugins/ui/validation'

export type Config = config.Config
export type Settings = config.Settings

local function build(context: plugin.Context, settings: Settings): ui.Service
  local registry: owners.Registry = {}
  local services: panel.Services = {
    focus = context:require(focus.capability),
    surfaces = context:require(surfaces.capability),
    owners = registry,
  }
  local panels: { ui.Panel } = {}
  local names: { [string]: boolean } = {}
  local generation: ui.Generation = { kind = 'ui-generation' }
  table.freeze(generation)
  return {
    newPanel = function(_self: ui.Service, owner: ui.Owner, options: ui.PanelOptions): ui.Panel
      context:checkOwner(owner)
      options = validation.panel(options)
      local name = options.name
      assert(not names[name], 'ui: duplicate panel name ' .. tostring(name))
      local created: ui.Panel
      names[name] = true
      local ok, result = pcall(function(): ui.Panel
        return panel.new(context, owner, options, services, settings.theme, settings.draw, generation, function(): ()
          names[name] = nil
          local index = table.find(panels, created)
          if index then
            table.remove(panels, index)
          end
        end)
      end)
      if not ok then
        names[name] = nil
        error(result, 0)
      end
      created = result
      panels[#panels + 1] = created
      return created
    end,
    panels = function(_self: ui.Service): { read [number]: ui.Panel }
      local result: { ui.Panel } = {}
      for _, current in ipairs(panels) do
        if not current.dead then
          result[#result + 1] = current
        end
      end
      return table.freeze(result)
    end,
  }
end

return plugin.provider<<Config, Settings, ui.Service>> {
  name = 'ui',
  schema = config,
  capability = ui.capability,
  requires = { focus = focus.capability, surfaces = surfaces.capability },
  build = build,
}
