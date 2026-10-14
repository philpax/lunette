-- Renders owner-scoped menu actions on a tracked wrist through the neutral UI service.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local config = require '@self/config'
local rows = require '@self/private/rows'

export type Config = config.Config
export type Settings = config.Settings

-- The closed menu is one square button in its own logical space.
local COMPACT = 100

local function wristPose(device: Device, offset: vector): Mat4
  local x, y, z, angle, ax, ay, az = lovr.headset.getPose(device)
  local pose = lovr.math.newMat4(x, y, z, angle, ax, ay, az)
  return pose:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/menu',
  schema = config.schema,
  requires = { ui.capability, frame.capability, menu.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local uiService: ui.Service = context:require(ui.capability)
    local menuService: menu.Service = context:require(menu.capability)
    local frameService: frame.Service = context:require(frame.capability)
    local expanded = settings.expanded
    local panel = uiService:newPanel(context, {
      name = 'desktop/menu',
      width = settings.size,
      height = settings.size,
      logicalWidth = COMPACT,
      logicalHeight = COMPACT,
      visible = false,
      grabbable = false,
      theme = {
        hapticStrength = settings.haptic.strength,
        hapticDuration = settings.haptic.duration,
        rowHeight = expanded.rowHeight,
      },
    })
    local device: Device = if settings.hand == 'left' then 'hand/left' else 'hand/right'
    local opened, tracked = false, false
    local button: ui.Button? = nil
    local list: ui.List? = nil
    local snapshot: rows.Snapshot = {}
    local function live(): boolean
      return context:active() and not panel.dead
    end
    local function rebuild(value: boolean): ()
      if not live() then
        return
      end
      opened = value
      if button and not button.dead then
        button:destroy()
      end
      if list and not list.dead then
        list:destroy()
      end
      button, list = nil, nil
      snapshot = {}
      if opened then
        panel:setSize(expanded.width, expanded.height, expanded.logicalWidth, expanded.logicalHeight)
      else
        panel:setSize(settings.size, settings.size, COMPACT, COMPACT)
      end
      panel:setTitlebar(if opened
        then {
          title = 'Menu',
          draggable = false,
          onClose = function(): ()
            if live() and tracked then
              rebuild(false)
            end
          end,
        }
        else nil)
      if not opened then
        button = panel:button {
          id = 'open',
          label = 'Menu',
          bounds = { x = 0, y = 0, width = COMPACT, height = COMPACT },
          onActivate = function(): ()
            if live() and tracked then
              rebuild(true)
            end
          end,
        }
      else
        snapshot = menuService:list()
        list = panel:list {
          id = 'actions',
          label = 'Actions',
          bounds = { x = 8, y = 8, width = expanded.logicalWidth - 16, height = expanded.logicalHeight - 16 },
          items = rows.items(snapshot),
          onChange = function(id: string): ()
            local current = list
            if not live() or not tracked or not opened or not current or current.dead then
              return
            end
            local descriptor = rows.find(snapshot, id)
            current:setSelected(nil)
            if descriptor and descriptor.enabled then
              -- Failed results are already reported by the broker; unavailable registrations are inert.
              menuService:invoke(descriptor.id, descriptor.token)
            end
          end,
        }
      end
    end
    rebuild(false)
    menuService:onChanged(context, {
      run = function(): ()
        local current = list
        if live() and opened and current and not current.dead then
          snapshot = menuService:list()
          current:setItems(rows.items(snapshot))
        end
      end,
    })
    frameService:onUpdate(context, {
      phase = 'scene',
      order = 1,
      run = function(_dt: number): ()
        if not live() then
          return
        end
        local nextTracked = lovr.headset.isTracked(device)
        if not nextTracked then
          if tracked then
            panel:setVisible(false)
            if opened then
              rebuild(false)
            end
          end
          tracked = false
          return
        end
        panel:setPose(wristPose(device, settings.offset))
        if not tracked then
          panel:setVisible(true)
        end
        tracked = true
      end,
    })
    frameService:onDraw(context, {
      phase = 'scene',
      order = 1,
      run = function(pass: Pass): ()
        if live() and tracked then
          panel:draw(pass)
        end
      end,
    })
  end,
}
