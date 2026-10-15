-- Memberships, exclusions, and overrides end with their owning effects.

local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local listeners = require '@lunette-plugins/registration/listeners'
local overrides = require './overrides'
local inspection = require '@lunette-contracts/inspection'

type Panel = tags.Panel
type Owner = tags.Owner

type Listener = {
  tag: tags.Tag?,
  run: (tags.Change) -> (),
}

type Mutable = {
  name: string,
  index: number,
  dead: boolean,
  selected: boolean,
  add: (tags.Tag, Owner, Panel) -> boolean,
  remove: (tags.Tag, Owner, Panel) -> boolean,
  exclude: (tags.Tag, Owner, Panel) -> plugin.Effect,
  has: (tags.Tag, Panel) -> boolean,
  panels: (tags.Tag) -> { Panel },
  setSelected: (tags.Tag, Owner, boolean) -> plugin.Effect,
}

-- A tag ends when its last holder releases it.
type Record = {
  tag: tags.Tag,
  holders: { [Owner]: plugin.Effect },
  inspect: () -> { inspection.Registration },
  destroy: () -> boolean,
}

local LISTENER_KEYS: { string } = { 'tag', 'run' }
local HOLD_KEYS: { string } = { 'name', 'index' }

-- Attempts every effect disposal, then raises the first failure.
local function disposeAll(effects: { plugin.Effect }): ()
  local failure: unknown = nil
  for _, effect in ipairs(effects) do
    local ok, raised = pcall(function()
      effect:dispose()
    end)
    if not ok and failure == nil then
      failure = raised
    end
  end
  if failure ~= nil then
    error(failure, 0)
  end
end

local function create(context: plugin.Context): tags.Service
  -- Names are unique among live tags.
  local records: { [string]: Record } = {}
  local count = 0
  local heard = listeners.new<<Listener>>(context)

  local function notify(tag: tags.Tag, kind: tags.ChangeKind): ()
    local change: tags.Change = table.freeze { tag = tag, kind = kind }
    heard:each('tags: a change listener', function(listener: Listener): ()
      listener.run(change)
    end, function(listener: Listener): boolean
      return listener.tag == nil or listener.tag == tag
    end)
  end

  local function find(_self: tags.Service, name: string): tags.Tag?
    local record = records[name]
    return record and record.tag
  end

  local function make(name: string, settings: tags.Hold): Record
    local created: Mutable
    local record: Record
    local current: { Panel } = {}
    local held: { Panel } = {}
    local holds: { [Panel]: { [Owner]: plugin.Effect } } = {}
    local exclusions: { [Panel]: { [Owner]: plugin.Effect } } = {}

    -- Members preserve first-hold order and exclude panels with live exclusions.
    local function settleMembers(): ()
      local members: { Panel } = {}
      for _, panel in ipairs(held) do
        if not panel.dead and next(exclusions[panel] or {}) == nil then
          members[#members + 1] = panel
        end
      end
      local changed = #members ~= #current
      if not changed then
        for index, panel in ipairs(members) do
          if current[index] ~= panel then
            changed = true
            break
          end
        end
      end
      current = members
      if changed and not created.dead then
        notify(created, 'membership')
      end
    end

    local function forget(panel: Panel): ()
      holds[panel] = nil
      local index = table.find(held, panel)
      if index then
        table.remove(held, index)
      end
    end

    -- Dead panels release their membership and exclusion effects. The panels service announces their removal.
    local function prune(): ()
      local ended: { plugin.Effect } = {}
      for index = #held, 1, -1 do
        local panel = held[index]
        if panel.dead then
          for _, effect in pairs(holds[panel] or {}) do
            ended[#ended + 1] = effect
          end
          forget(panel)
        end
      end
      for panel, excluders in pairs(exclusions) do
        if panel.dead then
          for _, effect in pairs(excluders) do
            ended[#ended + 1] = effect
          end
          exclusions[panel] = nil
        end
      end
      for index = #current, 1, -1 do
        if current[index].dead then
          table.remove(current, index)
        end
      end
      disposeAll(ended)
    end

    local function members(_self: tags.Tag): { Panel }
      prune()
      return table.clone(current)
    end

    local selection: overrides.Stack<boolean>
    selection = overrides.new(context, false, function(): ()
      if created.dead then
        return
      end
      local value: boolean = selection:value()
      if created.selected ~= value then
        created.selected = value
        notify(created, 'selection')
      end
    end)

    local function destroy(): boolean
      if created.dead then
        return false
      end
      created.dead = true
      local ended: { plugin.Effect } = {}
      for _, holders in pairs(holds) do
        for _, effect in pairs(holders) do
          ended[#ended + 1] = effect
        end
      end
      for _, excluders in pairs(exclusions) do
        for _, effect in pairs(excluders) do
          ended[#ended + 1] = effect
        end
      end
      for _, effect in ipairs(selection:clear()) do
        ended[#ended + 1] = effect
      end
      for _, effect in pairs(record.holders) do
        ended[#ended + 1] = effect
      end
      table.clear(record.holders)
      table.clear(holds)
      table.clear(exclusions)
      table.clear(held)
      table.clear(current)
      records[name] = nil
      count -= 1
      local ok, failure = pcall(disposeAll, ended)
      notify(created, 'destroyed')
      if not ok then
        error(failure, 0)
      end
      return true
    end

    created = {
      name = name,
      index = settings.index or (count + 1),
      selected = false,
      dead = false,
      add = function(_self: tags.Tag, caller: Owner, panel: Panel): boolean
        context:checkOwner(caller)
        if created.dead or panel.dead then
          return false
        end
        local holders = holds[panel]
        if holders and holders[caller] then
          return false
        end
        local effect = context:acquire(caller, function(): () -> ()
          if not holds[panel] then
            holds[panel] = {}
            held[#held + 1] = panel
          end
          return function(): ()
            local remaining = holds[panel]
            if not remaining then
              return
            end
            remaining[caller] = nil
            if next(remaining) == nil then
              forget(panel)
              settleMembers()
            end
          end
        end)
        local current = holds[panel]
        if current then
          current[caller] = effect
        end
        settleMembers()
        return true
      end,
      -- An owner removes its own membership; another owner's membership is excluded instead.
      remove = function(_self: tags.Tag, caller: Owner, panel: Panel): boolean
        context:checkOwner(caller)
        local holders = holds[panel]
        if not holders then
          return false
        end
        local mine = holders[caller]
        if not mine then
          error("tags: the tag '" .. name .. "' holds that panel for another owner; exclude it instead", 2)
        end
        mine:dispose()
        return true
      end,
      exclude = function(_self: tags.Tag, caller: Owner, panel: Panel): plugin.Effect
        context:checkOwner(caller)
        if type(panel) ~= 'table' then
          error('tags exclude: panel is a panel, not a ' .. type(panel), 2)
        end
        local existing = exclusions[panel] and exclusions[panel][caller]
        if existing then
          return existing
        end
        local effect = context:acquire(caller, function(): () -> ()
          if not exclusions[panel] then
            exclusions[panel] = {}
          end
          return function(): ()
            local remaining = exclusions[panel]
            if not remaining then
              return
            end
            remaining[caller] = nil
            if next(remaining) == nil then
              exclusions[panel] = nil
              settleMembers()
            end
          end
        end)
        if created.dead or panel.dead then
          effect:dispose()
          return effect
        end
        local current = exclusions[panel]
        if current then
          current[caller] = effect
        end
        settleMembers()
        return effect
      end,
      has = function(self: tags.Tag, panel: Panel): boolean
        return table.find(members(self), panel) ~= nil
      end,
      panels = members,
      setSelected = function(_self: tags.Tag, caller: Owner, selected: boolean): plugin.Effect
        context:checkOwner(caller)
        if type(selected) ~= 'boolean' then
          error('tags setSelected: selected is a boolean, not a ' .. type(selected), 2)
        end
        if created.dead then
          -- A dead tag takes no override, so the caller receives an effect that is already released.
          local inert = context:acquire(caller, function(): () -> ()
            return function(): () end
          end)
          inert:dispose()
          return inert
        end
        local effect, changed = selection:set(caller, selected)
        if changed then
          created.selected = selection:value()
          notify(created, 'selection')
        end
        return effect
      end,
    }
    local tag: tags.Tag = created
    record = {
      tag = tag,
      holders = {},
      destroy = destroy,
      inspect = function(): { inspection.Registration }
        local result: { inspection.Registration } = {}
        for caller in pairs(record.holders) do
          result[#result + 1] = inspection.registration(
            'hold',
            'tags.hold',
            caller,
            name,
            not created.dead and context:owns(caller),
            { index = created.index, selected = created.selected }
          )
        end
        for target, owners in pairs(holds) do
          local details = { excluded = next(exclusions[target] or {}) ~= nil }
          for caller in pairs(owners) do
            result[#result + 1] = inspection.registration(
              'membership',
              'tags.add',
              caller,
              name,
              not created.dead and context:owns(caller),
              details
            )
          end
        end
        for _, owners in pairs(exclusions) do
          for caller in pairs(owners) do
            result[#result + 1] = inspection.registration(
              'exclusion',
              'tags.exclude',
              caller,
              name,
              not created.dead and context:owns(caller)
            )
          end
        end
        for _, entry in ipairs(selection:inspect()) do
          result[#result + 1] = inspection.registration(
            'selection',
            'tags.setSelected',
            entry.owner,
            name,
            not created.dead and context:owns(entry.owner),
            { selected = entry.value, current = entry.current }
          )
        end
        return result
      end,
    }
    records[name] = record
    count += 1
    notify(created, 'created')
    return record
  end

  -- A hold keeps the tag alive until its last holder releases it.
  local function hold(_self: tags.Service, caller: Owner, wanted: tags.Hold): (tags.Tag, plugin.Effect)
    context:checkOwner(caller)
    plugin.rejectUnknownFields('tags hold', wanted, HOLD_KEYS, 2)
    local name = wanted.name
    if type(name) ~= 'string' or name == '' then
      error('tags hold: name is a non-empty tag name, not ' .. tostring(name), 2)
    end
    local record = records[name] or make(name, wanted)
    local previous = record.holders[caller]
    if previous then
      return record.tag, previous
    end
    local effect = context:acquire(caller, function(): () -> ()
      return function(): ()
        if record.holders[caller] == nil then
          return
        end
        record.holders[caller] = nil
        if next(record.holders) == nil then
          record.destroy()
        end
      end
    end)
    record.holders[caller] = effect
    return record.tag, effect
  end

  local function all(_self: tags.Service): { tags.Tag }
    local result: { tags.Tag } = {}
    for _, record in records do
      result[#result + 1] = record.tag
    end
    table.sort(result, function(a: tags.Tag, b: tags.Tag): boolean
      return if a.index == b.index then a.name < b.name else a.index < b.index
    end)
    return result
  end

  local function onChanged(_self: tags.Service, caller: Owner, listener: tags.ChangeListener): plugin.Effect
    listeners.check('tags onChanged', listener, LISTENER_KEYS)
    local wanted = listener.tag
    if wanted ~= nil then
      local record = records[wanted.name]
      if not record or record.tag ~= wanted then
        error('tags onChanged: tag is a live tag of this service', 2)
      end
    end
    return heard:add(caller, { tag = wanted, run = listener.run }, if wanted then { tag = wanted.name } else nil)
  end

  local service: tags.Service
  service = {
    inspect = function(_self: tags.Service): inspection.Snapshot
      local result = heard:inspect 'tags.onChanged'
      for _, tag in all(service) do
        for _, entry in ipairs(records[tag.name].inspect()) do
          result[#result + 1] = entry
        end
      end
      return inspection.snapshot(result, { tags = count })
    end,
    hold = hold,
    all = all,
    find = find,
    onChanged = onChanged,
  }
  context:effect(function(): () -> ()
    return function(): ()
      for _, record in table.clone(records) do
        record.destroy()
      end
      heard:clear()
    end
  end)
  return service
end

return create
