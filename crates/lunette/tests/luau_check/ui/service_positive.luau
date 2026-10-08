local ui = require '@lunette-contracts/ui'
local plugin = require '@lunette-plugin'
local surface = require '@lunette-contracts/surface'

local function substitute(panel: ui.Panel): ui.Service
  return {
    newPanel = function(_self: ui.Service, _owner: ui.Owner, options: ui.PanelOptions): ui.Panel
      assert(options.name ~= '' and options.width > 0)
      return panel
    end,
    newTitlebar = function(
      _self: ui.Service,
      _owner: ui.Owner,
      _name: string,
      _target: surface.Surface,
      _options: ui.TitlebarOptions,
      _visible: (() -> boolean)?
    ): ui.Titlebar
      return {
        dead = false,
        update = function(_: ui.Titlebar, _: ui.TitlebarOptions) end,
        sync = function(_: ui.Titlebar) end,
        draw = function(_: ui.Titlebar, _: Pass) end,
        destroy = function(_: ui.Titlebar): boolean
          return true
        end,
      }
    end,
    panels = function(_self: ui.Service): { read [number]: ui.Panel }
      return { panel }
    end,
  }
end

local function publish(publisher: plugin.Publisher, panel: ui.Panel): ()
  local service: ui.Service = substitute(panel)
  publisher:provide(ui.capability, service)
end

return { substitute = substitute, publish = publish }
