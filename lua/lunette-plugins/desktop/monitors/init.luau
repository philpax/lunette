-- Mirrors selected host monitors in a non-overlapping row. Tagging runs as a child, so tag-provider outages leave mirrors active.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'

export type Config = {
  read select: { string }?,
  read placement: {
    read center: { number }?,
    read width: number?,
    read gap: number?,
  }?,
  read tags: { string }?,
}

export type Settings = {
  read select: { string },
  read placement: {
    read center: { number },
    read width: number,
    read gap: number,
  },
  read tags: { string },
}

local DEFAULTS: Settings = {
  select = {},
  placement = { center = { 0, 1.5, -2 }, width = 2, gap = 0.1 },
  tags = {},
}

local required: plugin.Declaration = { panels = panels.capability }

local function checkNames(option: string, names: { string }): ()
  for index, name in ipairs(names) do
    if type(name) ~= 'string' or name == '' then
      error(string.format('plugin desktop/monitors: option %s[%d] is a non-empty name', option, index), 0)
    end
  end
end

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/monitors', defaults = DEFAULTS, config = config }
  checkNames('select', settings.select)
  checkNames('tags', settings.tags)
  local placement = settings.placement
  plugin.checkNumbers('desktop/monitors', 'placement.center', placement.center, 3)
  if not (placement.width > 0) then
    error('plugin desktop/monitors: option placement.width is a positive number, not ' .. placement.width, 0)
  end
  if not (placement.gap >= 0) then
    error('plugin desktop/monitors: option placement.gap is zero or more, not ' .. placement.gap, 0)
  end
  return settings
end

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
}

local function tagging(shared: Shared, names: { string }): plugin.Definition<{}>
  return plugin.define {
    name = 'desktop/monitors/tags',
    requires = { tags = tags.capability },
    init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
      local tagService: tags.Service = context:require(tags.capability)
      local function tag(mirror: panels.MonitorPanel): ()
        if mirror.dead then
          return
        end
        for _, name in ipairs(names) do
          local found = tagService:find(name)
          if found then
            found:add(context, mirror)
          end
        end
      end
      tagService:onChanged(context, {
        run = function(change: tags.Change): ()
          if change.kind == 'created' and table.find(names, change.tag.name) then
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
  }
end

return plugin.define {
  name = 'desktop/monitors',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings = resolve(config)
    local panelService: panels.Service = context:require(panels.capability)
    local placement = settings.placement
    local selected: { [string]: boolean }? = nil
    if #settings.select > 0 then
      local names: { [string]: boolean } = {}
      for _, name in ipairs(settings.select) do
        names[name] = true
      end
      selected = names
    end
    local shared: Shared = { mirrors = {}, tag = nil }
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
      local center = placement.center
      local x = center[1] + offsetOf(place) * (placement.width + placement.gap)
      return lovr.math.newMat4():translate(x, center[2], center[3])
    end

    local function mirror(monitor: lunette.Monitor): ()
      if monitor.dead or (selected and not selected[monitor.name]) then
        return
      end
      local existing = shared.mirrors[monitor.id]
      if existing and not existing.dead then
        if not existing.source.dead then
          return
        end
        -- A replug can arrive before the update retires the panel's stale handle.
        existing:destroy(context)
      end
      if panelService:forSource(monitor) then
        return
      end
      local mirrored = context:effect(function(): () -> ()
        monitor:mirror()
        return function(): ()
          if not monitor.dead then
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
        end,
      })
      local tag = shared.tag
      if tag then
        tag(created)
      end
    end

    if #settings.tags > 0 then
      context:child(tagging(shared, settings.tags), {})
    end
    context:on {
      event = lunette.onMonitorAdded,
      run = function(event: lunette.MonitorAddedEvent)
        if event.monitor then
          mirror(event.monitor)
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
      mirror(monitor)
    end
  end,
}
