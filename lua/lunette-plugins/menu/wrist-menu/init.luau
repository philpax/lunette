-- Renders owner-scoped menu actions on a tracked wrist through the UI host and the standard kinds. A gauntlet stays on
-- the wrist with the shortcuts, the menu button, and the local time; the menu button opens the list beside it, as if
-- expanded out of it. Grabbing the open list tears it off the wrist: it stays where it is released, as a world panel,
-- until it is closed, when it returns beside the gauntlet. On the wrist, both fade as they turn away from the head.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local ui = require '@lunette-plugins/ui/react'
local config = require '@self/config'
local rows = require '@self/private/rows'
local view = require '@self/private/view'
local facing = require '@self/private/facing'

export type Config = config.Config
export type Settings = config.Settings

local TIME_FORMAT = '%H:%M:%S'
-- The torn-off menu's name for placement memory.
local PLACEMENT_KEY = 'desktop/menu'

-- Whether a grab moved the panel from the pose the menu last gave it.
local function moved(panel: uiHost.Panel, placed: { number }): boolean
  for index, value in { panel:pose():unpack(true) } do
    if math.abs(value - placed[index]) > 1e-6 then
      return true
    end
  end
  return false
end

-- The menu rolls this far counter-clockwise about its own face, so it reads level on a wrist turned towards the head.
local ROLL = 5 * math.pi / 16
-- Metres the menu stands out from the wrist, towards the viewer.
local LIFT = 0.03
-- The menu wraps the wrist as a strip would: bent away from the viewer along its long, vertical axis, around a cylinder
-- this many metres out from the wrist's centre. The cylinder's axis is therefore the panel's horizontal.
local WRIST_RADIUS = 0.035
local WRAP_CURVE = -1 / (WRIST_RADIUS + LIFT)
local WRAP_AXIS = math.pi / 2

-- The menu sits a button size below the offset, along its own face.
local function wristPose(device: Device, offset: vector, size: number): Mat4
  local x, y, z, angle, ax, ay, az = lovr.headset.getPose(device)
  local pose = lovr.math.newMat4(x, y, z, angle, ax, ay, az)
  return pose
    :translate(offset)
    :rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
    :rotate(ROLL, 0, 0, 1)
    :translate(0, -size, LIFT)
end

-- Metres between the gauntlet's right edge and the list's left edge while the list is on the wrist.
local LIST_GAP = 0.01

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/menu',
  schema = config.schema,
  requires = { uiHost.capability, uiComponents.capability, frame.capability, menu.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local menuService: menu.Service = context:require(menu.capability)
    local frameService: frame.Service = context:require(frame.capability)
    local expanded = settings.expanded
    -- Both panels hold the control that brings hidden panels back, so they stay when panels are hidden.
    local gauntlet = host:newPanel(context, {
      name = 'desktop/menu',
      size = 'content',
      width = settings.size,
      height = settings.size * 2,
      grabbable = false,
      essential = true,
      curve = WRAP_CURVE,
      curveAxis = WRAP_AXIS,
      visible = false,
    })
    local list = host:newPanel(context, {
      name = 'desktop/menu/list',
      size = 'content',
      width = expanded.width,
      height = expanded.height,
      grabbable = true,
      essential = true,
      visible = false,
    })
    -- The list is keyed only while it is torn off, so placement memory never moves it on the wrist.
    list:setPlacementKey(nil)
    local device: Device = if settings.hand == 'left' then 'hand/left' else 'hand/right'
    local tracked = false
    -- Set while the open list is torn off the wrist.
    local detached = false
    local gauntletShown, listShown = false, false
    -- The pose the menu last placed the list at beside the gauntlet, which a grab changes.
    local placed: { number }? = nil
    local opened = ui.store(false)
    local snapshot = ui.store(menuService:list() :: rows.Snapshot)
    local time = ui.store(os.date(TIME_FORMAT))
    local function live(): boolean
      return context:active() and not gauntlet.dead and not list.dead
    end
    local function setOpened(value: boolean): ()
      if not live() then
        return
      end
      if not value then
        detached = false
        placed = nil
        list:setPlacementKey(nil)
      end
      opened:set(value)
    end
    local function reachable(): boolean
      return tracked or detached
    end
    local function showList(value: boolean): ()
      if value ~= listShown then
        listShown = value
        list:setVisible(value)
      end
    end
    local function showGauntlet(value: boolean): ()
      if value ~= gauntletShown then
        gauntletShown = value
        gauntlet:setVisible(value)
      end
    end
    ui.mount(
      gauntlet,
      view.Gauntlet {
        opened = opened,
        snapshot = snapshot,
        time = time,
        shortcuts = settings.shortcuts,
        size = settings.size,
        toggle = function(): ()
          if tracked then
            setOpened(not opened:get())
          end
        end,
        shortcut = function(descriptor: menu.Descriptor): ()
          if live() and tracked then
            -- Failed results are already reported by the broker; unavailable registrations are inert.
            menuService:invoke(descriptor.id, descriptor.token)
          end
        end,
      },
      { components = components, owner = context }
    )
    ui.mount(
      list,
      view.List {
        snapshot = snapshot,
        time = time,
        width = expanded.width,
        height = expanded.height,
        close = function(): ()
          if reachable() then
            setOpened(false)
          end
        end,
        invoke = function(descriptor: menu.Descriptor): ()
          if live() and reachable() and opened:get() then
            menuService:invoke(descriptor.id, descriptor.token)
          end
        end,
      },
      { components = components, owner = context }
    )
    -- The saved state last written, so a change saves once.
    local savedOpen, savedDetached = settings.open, settings.detached
    local function remember(): ()
      local isOpen = opened:get()
      if isOpen ~= savedOpen or detached ~= savedDetached then
        savedOpen, savedDetached = isOpen, detached
        context:save { open = isOpen, detached = detached }
      end
    end
    -- A list left torn off returns torn off, and placement memory moves it to where it was left before it is first
    -- drawn. A list left open on the wrist opens again once the wrist is tracked.
    if settings.detached then
      setOpened(true)
      detached = true
      list:setPlacementKey(PLACEMENT_KEY)
      showList(true)
    elseif settings.open then
      setOpened(true)
    end
    menuService:onChanged(context, {
      run = function(): ()
        if live() then
          snapshot:set(menuService:list())
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
        remember()
        local now = os.date(TIME_FORMAT)
        if now ~= time:get() then
          time:set(now)
        end
        if not detached and placed and opened:get() and moved(list, placed) then
          detached = true
          -- Keyed as it is torn off, so its drop is saved without moving it out of hand.
          list:setPlacementKey(PLACEMENT_KEY)
        end
        tracked = lovr.headset.isTracked(device)
        if not tracked then
          showGauntlet(false)
          -- A list on the wrist closes with it; a torn-off list stays.
          if not detached and opened:get() then
            setOpened(false)
          end
          placed = nil
          showList(opened:get() and detached)
          return
        end
        local pose = wristPose(device, settings.offset, settings.size)
        gauntlet:setPose(pose)
        local hx, hy, hz = lovr.headset.getPose 'head'
        local opacity = facing.opacity(facing.angle(pose, vector.pack(hx, hy, hz)), settings.facing)
        gauntlet:setOpacity(opacity)
        showGauntlet(true)
        if detached then
          list:setOpacity(1)
        elseif opened:get() then
          local gauntletWidth = gauntlet:size()
          local listWidth = list:size()
          local listPose = lovr.math.newMat4(pose):translate(gauntletWidth / 2 + LIST_GAP + listWidth / 2, 0, 0)
          list:setPose(listPose)
          list:setOpacity(opacity)
          placed = { listPose:unpack(true) }
        end
        showList(opened:get())
      end,
    })
  end,
}
