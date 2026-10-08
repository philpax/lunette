-- Opts native panels without their own chrome into the shared UI titlebar.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local config = require '@lunette-plugins/desktop/decorations/config'
local controls = require '@lunette-plugins/desktop/decorations/controls'
local titlebarStyle = require '@lunette-plugins/ui/titlebar-style'

export type Color = config.Color
export type Style = config.Style
export type Config = config.Config
export type Settings = config.Settings

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/decorations',
  requires = { frame = frame.capability, panels = panels.capability, ui = ui.capability },
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local frames = context:require(frame.capability)
    local registry = context:require(panels.capability)
    local widgets = context:require(ui.capability)
    local style = if settings.style then titlebarStyle.project(settings.style) else nil
    local entries: { [panels.Panel]: ui.Titlebar } = {}
    local refusal: string? = nil
    local refresh: () -> ()
    refresh = function(): ()
      local live: { [panels.Panel]: boolean } = {}
      for _, panel in registry:all() do
        if panel.dead or panel.source.dead or panel.chrome then
          continue
        end
        live[panel] = true
        local options = controls.options(context, panel, style, refusal, function(): ()
          if context:active() and not panel.dead and not panel.source.dead then
            local accepted, reason = lunette.selectMonitors()
            refusal = if accepted then nil else reason
            refresh()
          end
        end)
        local bar = entries[panel]
        if bar then
          bar:update(options)
        else
          entries[panel] = widgets:newTitlebar(
            context,
            'desktop/decorations/' .. panel.kind .. '/' .. panel.source.id,
            panel,
            options,
            function(): boolean
              return not panel.hidden and not panel.chrome
            end
          )
        end
      end
      for panel, bar in entries do
        if not live[panel] then
          entries[panel] = nil
          bar:destroy()
        end
      end
    end
    registry:onAdded(context, function(_panel: panels.Panel): ()
      refresh()
    end)
    registry:onRemoved(context, {
      run = function(panel: panels.Panel): ()
        local bar = entries[panel]
        if bar then
          entries[panel] = nil
          bar:destroy()
        end
      end,
    })
    refresh()
    frames:onUpdate(context, {
      phase = 'scene',
      run = function(_dt: number): ()
        refresh()
      end,
    })
    frames:onDraw(context, {
      phase = 'scene',
      run = function(pass: Pass): ()
        for _, bar in entries do
          bar:draw(pass)
        end
      end,
    })
  end,
}).definition
