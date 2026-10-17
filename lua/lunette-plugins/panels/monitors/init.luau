-- Mirrors selected host monitors in a non-overlapping row, except those the user closed. Tagging and the wrist-menu
-- actions run as children, so tag-provider and menu outages leave mirrors active.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'
local menu = require '@lunette-contracts/menu'
local frame = require '@lunette-contracts/frame'
local toggle = require '@lunette-plugins/menu/toggle'

local config = require '@self/config'

type ChildConfig = {}
type ChildSettings = {}

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { panels.capability }

-- Places alternate outward from the center, beginning to the right.
local function offsetOf(place: number): number
  if place % 2 == 1 then
    return (place + 1) / 2
  end
  return -place / 2
end

type Shared = {
  mirrors: { [unknown]: panels.MonitorPanel },
  tag: ((panels.MonitorPanel) -> ())?,
  -- Monitor ids not mirrored, by the user's choice.
  hidden: { [string]: boolean },
  -- The wrist-menu action of each monitor, while the menu runs.
  toggles: { [string]: toggle.Toggle },
  eligible: (lunette.Monitor) -> boolean,
  mirror: (lunette.Monitor) -> (),
  unmirror: (string) -> (),
  setHidden: (string, boolean) -> (),
  -- Hears each monitor that arrives, while the menu runs.
  added: ((lunette.Monitor) -> ())?,
}

-- The live monitor with an id. A replug brings a new handle for the same monitor.
local function monitorWithId(id: string): lunette.Monitor?
  for _, monitor in lunette.monitors() do
    if monitor.id == id and not monitor.dead then
      return monitor
    end
  end
  return nil
end

-- An action for each eligible monitor, which mirrors it or closes its mirror, in the wrist menu's Monitors group.
local function menuActions(shared: Shared): plugin.Definition<ChildConfig>
  return plugin.consumer<<ChildConfig, ChildSettings>>({
    name = 'desktop/monitors/menu',
    requires = { menu.capability, frame.capability },
    init = function(context: plugin.Context, _settings: ChildSettings): ()
      local menus: menu.Service = context:require(menu.capability)
      local function add(monitor: lunette.Monitor): ()
        local id = monitor.id
        if monitor.dead or shared.toggles[id] or not shared.eligible(monitor) then
          return
        end
        shared.toggles[id] = toggle.attach(context, menus, {
          id = 'desktop/monitors/' .. id,
          label = monitor.name,
          group = 'Monitors',
          visible = not shared.hidden[id],
          show = function(): ()
            local live = monitorWithId(id)
            if live then
              shared.mirror(live)
            end
          end,
          hide = function(): ()
            shared.unmirror(id)
          end,
          save = function(open: boolean): ()
            shared.setHidden(id, not open)
          end,
        })
      end
      -- The parent hears monitors arrive and passes each on, so the session has one subscription.
      context:effect(function(): () -> ()
        shared.added = add
        return function(): ()
          if shared.added == add then
            shared.added = nil
          end
          table.clear(shared.toggles)
        end
      end)
      for _, monitor in lunette.monitors() do
        add(monitor)
      end
      -- Monitors have no removal event, so a monitor that is gone loses its action at the next frame.
      context:require(frame.capability):onUpdate(context, {
        phase = 'scene',
        run = function(): ()
          for id, opened in shared.toggles do
            if not monitorWithId(id) then
              opened:dispose()
              shared.toggles[id] = nil
            end
          end
        end,
      })
    end,
  }).definition
end

local function tagging(shared: Shared, names: { read [number]: string }): plugin.Definition<ChildConfig>
  return plugin.consumer<<ChildConfig, ChildSettings>>({
    name = 'desktop/monitors/tags',
    requires = { tags.capability },
    init = function(context: plugin.Context, _settings: ChildSettings): ()
      local tagService: tags.Service = context:require(tags.capability)
      local function tag(mirror: panels.MonitorPanel): ()
        if mirror.dead then
          return
        end
        for _, name in names do
          local found = tagService:find(name)
          if found then
            found:add(context, mirror)
          end
        end
      end
      local function selected(name: string): boolean
        for _, candidate in names do
          if candidate == name then
            return true
          end
        end
        return false
      end
      tagService:onChanged(context, {
        run = function(change: tags.Change): ()
          if change.kind == 'created' and selected(change.tag.name) then
            for _, mirror in pairs(shared.mirrors) do
              if not mirror.dead then
                change.tag:add(context, mirror)
              end
            end
          end
        end,
      })
      context:effect(function(): () -> ()
        shared.tag = tag
        return function(): ()
          if shared.tag == tag then
            shared.tag = nil
          end
        end
      end)
      for _, mirror in pairs(shared.mirrors) do
        tag(mirror)
      end
    end,
  }).definition
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/monitors',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local panelService: panels.Service = context:require(panels.capability)
    local placement = settings.placement
    local selected: { [string]: boolean }? = nil
    if #settings.select > 0 then
      local names: { [string]: boolean } = {}
      for _, name in settings.select do
        names[name] = true
      end
      selected = names
    end
    local hidden: { [string]: boolean } = {}
    for _, id in settings.hidden do
      hidden[id] = true
    end
    local shared: Shared = {
      mirrors = {},
      tag = nil,
      hidden = hidden,
      toggles = {},
      eligible = function(): boolean
        return true
      end,
      mirror = function() end,
      unmirror = function() end,
      setHidden = function() end,
      added = nil,
    }
    -- Mirrors this plugin removes itself, as opposed to mirrors closed from their titlebars.
    local removing: { [panels.MonitorPanel]: boolean } = setmetatable({}, { __mode = 'k' }) :: any
    -- The monitor id that holds each place in the row.
    local places: { [number]: unknown } = {}

    local function freePlace(): number
      local place = 0
      while places[place] ~= nil do
        place += 1
      end
      return place
    end

    local function poseFor(place: number): Mat4
      local position = placement.center + vector.pack(offsetOf(place) * (placement.width + placement.gap), 0, 0)
      return lovr.math.newMat4():translate(position)
    end

    local function eligible(monitor: lunette.Monitor): boolean
      return not selected or selected[monitor.name] == true
    end

    local function mirror(monitor: lunette.Monitor): ()
      if monitor.dead or not eligible(monitor) then
        return
      end
      local existing = shared.mirrors[monitor.id]
      if existing and not existing.dead then
        if not existing.source.dead then
          return
        end
        -- A replug can arrive before the update retires the panel's stale handle.
        removing[existing] = true
        existing:destroy(context)
      end
      if panelService:forSource(monitor) then
        return
      end
      local mirrored = context:effect(function(): () -> ()
        monitor:mirror()
        return function(): ()
          if not monitor.dead and (monitor.mirrored or monitor.pending) then
            monitor:dismiss()
          end
        end
      end)
      local place = freePlace()
      local created = panelService:fromMonitor(context, monitor, { pose = poseFor(place), width = placement.width })
      if created.dead then
        mirrored:dispose()
        return
      end
      shared.mirrors[monitor.id] = created
      places[place] = monitor.id
      local removal: plugin.Effect
      removal = panelService:onRemoved(context, {
        panel = created,
        run = function(): ()
          if shared.mirrors[monitor.id] == created then
            shared.mirrors[monitor.id] = nil
          end
          if places[place] == monitor.id then
            places[place] = nil
          end
          removal:dispose()
          mirrored:dispose()
          -- A mirror closed from its titlebar, while its monitor is still attached, stays closed.
          if not removing[created] and context:active() and not monitor.dead then
            local opened = shared.toggles[monitor.id]
            if opened then
              opened:set(false)
            else
              shared.setHidden(monitor.id, true)
            end
          end
        end,
      })
      local tag = shared.tag
      if tag then
        tag(created)
      end
    end

    shared.eligible = eligible
    shared.mirror = mirror
    shared.unmirror = function(id: string): ()
      local existing = shared.mirrors[id]
      if existing and not existing.dead then
        removing[existing] = true
        existing:destroy(context)
      end
    end
    shared.setHidden = function(id: string, value: boolean): ()
      if (hidden[id] == true) == value then
        return
      end
      hidden[id] = if value then true else nil
      local list: { string } = {}
      for name in hidden do
        table.insert(list, name)
      end
      table.sort(list)
      context:save { hidden = list }
    end

    if #settings.tags > 0 then
      context:child(tagging(shared, settings.tags))
    end
    context:on {
      event = lunette.onMonitorAdded,
      run = function(event: lunette.MonitorAddedEvent)
        if not hidden[event.monitor.id] then
          mirror(event.monitor)
        end
        local added = shared.added
        if added then
          added(event.monitor)
        end
      end,
    }
    local present: { lunette.Monitor } = {}
    for _, monitor in pairs(lunette.monitors()) do
      present[#present + 1] = monitor
    end
    table.sort(present, function(first: lunette.Monitor, second: lunette.Monitor): boolean
      return tostring(first.name) < tostring(second.name)
    end)
    for _, monitor in ipairs(present) do
      if not hidden[monitor.id] then
        mirror(monitor)
      end
    end
    context:child(menuActions(shared))
  end,
}
