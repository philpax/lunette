-- Gives native panels without their own chrome a titlebar: a toolkit panel attached above the window or monitor
-- panel, which moves it when grabbed and offers its close request and monitor actions, inside a joined outline.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local vocabulary = require '@lunette-contracts/vocabulary'
local ui = require '@lunette-plugins/ui/react'
local config = require '@self/config'
local controls = require '@self/private/controls'

export type Config = config.Config
export type Settings = config.Settings

type TitlebarProps = { options: ui.Store<controls.Options> }

local Titlebar = ui.component('Titlebar', function(props: TitlebarProps): ui.Child
  local c = ui.useComponents()
  local options = ui.useStore(props.options)
  local buttons: { ui.Child } = {}
  for _, action in options.actions do
    buttons[#buttons + 1] = c.Button {
      key = action.id,
      label = action.label,
      variant = 'band',
      disabledReason = if action.enabled then nil else 'Waiting for the portal to answer.',
      onActivate = action.run,
    }
  end
  return c.Panel {
    c.Header {
      key = 'header',
      title = options.title,
      buttons,
      c.Button { key = 'close', label = '×', variant = 'band', onActivate = options.close },
    },
  }
end)

type Entry = {
  panel: uiHost.Panel,
  options: ui.WritableStore<controls.Options>,
  attachment: vocabulary.FrameAttachment?,
}

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/decorations',
  requires = { frame.capability, panels.capability, uiHost.capability, uiComponents.capability },
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local frames = context:require(frame.capability)
    local registry = context:require(panels.capability)
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local entries: { [panels.Panel]: Entry } = {}
    local refusal: string? = nil
    local function remove(target: panels.Panel): ()
      local entry = entries[target]
      if entry then
        entries[target] = nil
        if entry.attachment then
          entry.attachment:dispose()
        end
        entry.panel:destroy()
      end
    end
    local refresh: () -> ()
    refresh = function(): ()
      local theme = host:theme()
      local height = settings.height or theme.sizes.header
      local live: { [panels.Panel]: boolean } = {}
      for _, target in registry:all() do
        if target.dead or target.source.dead or target.chrome then
          continue
        end
        live[target] = true
        local options = controls.options(context, target, refusal, function(): ()
          if context:active() and not target.dead and not target.source.dead then
            local accepted, reason = lunette.selectMonitors()
            refusal = if accepted then nil else reason
            refresh()
          end
        end)
        local entry = entries[target]
        if entry then
          entry.options:set(options)
        else
          local store = ui.store(options)
          local surface = (target :: any) :: vocabulary.Surface
          local panel = host:newPanel(context, {
            name = `desktop/decorations/{target.kind}/{target.source.id}`,
            presentation = 'attach',
            target = surface,
            height = height,
          })
          -- The outline joins the titlebar where the panel service can draw it, around a flat panel.
          local attachment = if target.attachFrame
            then target:attachFrame(context, {
              headerHeight = height,
              headerRadius = theme.radii.panel,
              borderThickness = theme.sizes.headerRule,
              borderDepth = theme.elevation.panelDepth,
              borderColor = table.clone(theme.colors.header),
            })
            else nil
          ui.mount(panel, Titlebar { options = store }, { components = components, owner = context })
          entries[target] = { panel = panel, options = store, attachment = attachment }
        end
        local current = entries[target]
        -- A titlebar outside a joined outline leaves a small gap above its panel.
        local joined = current.attachment ~= nil and current.attachment:isJoined()
        current.panel:setGap(if joined then 0 else theme.spacing.sm)
        current.panel:setVisible(not target.hidden)
      end
      for target in table.clone(entries) do
        if not live[target] then
          remove(target)
        end
      end
    end
    -- A removed panel's titlebar ends at once, so it is never offered after its panel.
    registry:onRemoved(context, {
      run = function(target: panels.Panel): ()
        remove(target)
      end,
    })
    refresh()
    frames:onUpdate(context, {
      phase = 'scene',
      order = -300,
      run = function(_dt: number): ()
        refresh()
      end,
    })
  end,
}
