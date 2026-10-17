-- Adds an Accessibility action to the wrist menu, which opens a panel in front of the user for editing the session's
-- accessibility settings, so they are reachable in VR, and a Default appearance action that switches the host's
-- default appearance.

local plugin = require '@lunette-plugin'
local accessibility = require '@lunette-contracts/accessibility'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local ui = require '@lunette-plugins/ui/react'
local toggle = require '@lunette-plugins/menu/toggle'
local config = require '@self/config'

type Props = { service: accessibility.Service, close: () -> () }

local SCALES = {
  { value = 0.75, label = 'Small' },
  { value = 1, label = 'Default' },
  { value = 1.25, label = 'Large' },
  { value = 1.5, label = 'Larger' },
  { value = 2, label = 'Largest' },
}

local TIMINGS = {
  { value = 1, label = 'Default' },
  { value = 2, label = 'Longer' },
  { value = 3, label = 'Much longer' },
}

local SettingsPanel = ui.component('AccessibilitySettings', function(props: Props): ui.Child
  local c = ui.useComponents()
  local settings = ui.useStore(props.service.settings)
  local function set(name: string): (any) -> ()
    return function(value: any): ()
      props.service:update { [name] = value }
    end
  end
  return c.Panel {
    width = 0.42,
    title = 'Accessibility',
    onClose = props.close,
    c.Body {
      key = 'body',
      c.Section {
        key = 'display',
        title = 'Display',
        c.Slider {
          key = 'textScale',
          label = 'Text size',
          min = 0.75,
          max = 2,
          value = settings.textScale,
          detents = SCALES,
          format = '%.2f×',
          onCommit = set 'textScale',
        },
        c.Toggle {
          key = 'highContrast',
          label = 'High contrast',
          value = settings.highContrast,
          onChange = set 'highContrast',
        },
        c.Toggle {
          key = 'reducedMotion',
          label = 'Reduce motion',
          detail = 'Controls snap rather than ease.',
          value = settings.reducedMotion,
          onChange = set 'reducedMotion',
        },
      },
      c.Section {
        key = 'feedback',
        title = 'Feedback and timing',
        c.Toggle { key = 'haptics', label = 'Haptics', value = settings.haptics, onChange = set 'haptics' },
        c.Toggle { key = 'sounds', label = 'Sounds', value = settings.sounds, onChange = set 'sounds' },
        c.Slider {
          key = 'timing',
          label = 'Time to read and act',
          min = 1,
          max = 3,
          value = settings.timing,
          detents = TIMINGS,
          format = '%.1f×',
          onCommit = set 'timing',
        },
        c.Segmented {
          key = 'handedness',
          value = settings.handedness,
          options = { { id = 'left', label = 'Left hand' }, { id = 'right', label = 'Right hand' } },
          onChange = set 'handedness',
        },
      },
    },
  }
end)

return plugin.consumer<<config.Config, config.Settings>> {
  name = 'desktop/accessibility',
  schema = config.schema,
  requires = {
    accessibility.capability,
    menu.capability,
    frame.capability,
    uiHost.capability,
    uiComponents.capability,
  },
  init = function(context: plugin.Context, settings: config.Settings): ()
    local service = context:require(accessibility.capability)
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local actions = context:require(menu.capability)
    local open: uiHost.Panel? = nil
    local panel: toggle.Toggle
    -- The chord also switches default appearance, so the action's selection follows the host each frame.
    local appearanceShown = host:defaultAppearance()
    local appearance = actions:register(context, {
      id = 'desktop/default-appearance',
      label = 'Default appearance',
      group = 'Session',
      selected = appearanceShown,
      run = function(): ()
        host:setDefaultAppearance(not host:defaultAppearance())
      end,
    })
    context:require(frame.capability):onUpdate(context, {
      phase = 'scene',
      run = function(): ()
        local on = host:defaultAppearance()
        if on ~= appearanceShown then
          appearanceShown = on
          appearance:update { selected = on }
        end
      end,
    })
    -- The panel opens ahead of the user, or where it was last left, and stays there until it is grabbed and moved.
    panel = toggle.attach(context, actions, {
      id = 'desktop/accessibility',
      label = 'Accessibility',
      group = 'Session',
      visible = settings.visible,
      show = function(requested: boolean): ()
        local made = host:newPanel(context, { name = 'Accessibility' })
        ui.mount(
          made,
          SettingsPanel {
            service = service,
            close = function(): ()
              panel:set(false)
            end,
          },
          { components = components, owner = context }
        )
        open = made
        -- Traversal enters a panel the user asked for, so a controller can change settings without pointing.
        if requested then
          host:nextPanel()
        end
      end,
      hide = function(): ()
        if open then
          open:destroy()
          open = nil
        end
      end,
    })
  end,
}
