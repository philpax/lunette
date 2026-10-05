-- Mirrors selected host monitors in a non-overlapping row. Tagging runs as a child, so tag-provider outages leave mirrors active.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'

local config = require '@lunette-plugins/desktop/monitors/config'
local schema = require '@lunette-plugin/schema'

local childSchema = schema.object {}
type ChildConfig = schema.Input<typeof(childSchema)>
type ChildSettings = schema.Output<typeof(childSchema)>

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { panels = panels.capability }

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

local function tagging(shared: Shared, names: { read [number]: string }): plugin.Definition<ChildConfig>
  return plugin.consumer<<ChildConfig, ChildSettings>>({
    name = 'desktop/monitors/tags',
    requires = { tags = tags.capability },
    schema = childSchema,
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

return plugin.consumer<<Config, Settings>>({
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
      local position = placement.center + vector.pack(offsetOf(place) * (placement.width + placement.gap), 0, 0)
      return lovr.math.newMat4():translate(position)
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
}).definition
