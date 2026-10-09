-- Memberships, exclusions, and overrides end with their owning effects.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local listeners = require '@lunette-plugins/listeners'
local overrides = require '@lunette-plugins/tags/overrides'
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
  layout: string?,
  add: (tags.Tag, Owner, Panel) -> boolean,
  remove: (tags.Tag, Owner, Panel) -> boolean,
  exclude: (tags.Tag, Owner, tags.Exclusion) -> plugin.Effect,
  has: (tags.Tag, Panel) -> boolean,
  panels: (tags.Tag) -> { Panel },
  setSelected: (tags.Tag, Owner, tags.Selection) -> boolean,
  setLayout: (tags.Tag, Owner, tags.LayoutChoice) -> boolean,
}

-- A tag ends when its last holder releases it.
type Record = {
  tag: tags.Tag,
  holders: { [Owner]: plugin.Effect },
  inspect: () -> { inspection.Registration },
  destroy: () -> boolean,
}

local LISTENER_KEYS: { [string]: boolean } = { tag = true, run = true }
local HOLD_KEYS: { [string]: boolean } = { name = true, index = true, selected = true, layout = true }
local EXCLUSION_KEYS: { [string]: boolean } = { panel = true }
local LAYOUT_KEYS: { [string]: boolean } = { layout = true }

local function surfaceDetails(target: Panel): { [string]: string | number | boolean }
  local fields = (target :: unknown) :: { [string]: unknown }
  local dead = rawget(fields, 'dead')
  local details: { [string]: string | number | boolean } = {
    targetLiveness = if type(dead) == 'boolean' then (if dead then 'dead' else 'live') else 'unavailable',
  }
  local kind, source = rawget(fields, 'kind'), rawget(fields, 'source')
  if (kind == 'window' or kind == 'monitor') and (type(source) == 'userdata' or type(source) == 'table') then
    local id = if type(source) == 'table'
      then rawget(source :: { [string]: unknown }, 'id')
      else ((source :: unknown) :: lunette.Window | lunette.Monitor).id
    if (kind == 'window' and type(id) == 'number') or (kind == 'monitor' and type(id) == 'string') then
      details.sourceId, details.sourceKind = id, kind
    end
  end
  return details
end

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

local function checkOptions(what: string, options: tags.Hold): ()
  if options.index ~= nil and type(options.index) ~= 'number' then
    error(what .. ': index is a number, not a ' .. type(options.index), 3)
  end
  if options.selected ~= nil and type(options.selected) ~= 'boolean' then
    error(what .. ': selected is a boolean, not a ' .. type(options.selected), 3)
  end
  if options.layout ~= nil and type(options.layout) ~= 'string' then
    error(what .. ': layout is a layout name, not a ' .. type(options.layout), 3)
  end
end

local function create(context: plugin.Context): tags.Service
  local records: { Record } = {}
  local heard = listeners.new<<Listener>>(context)

  local function notify(tag: tags.Tag, kind: tags.ChangeKind): ()
    local change: tags.Change = table.freeze { tag = tag, kind = kind }
    heard:each('tags: a change listener', function(listener: Listener): ()
      listener.run(change)
    end, function(listener: Listener): boolean
      return listener.tag == nil or listener.tag == tag
    end)
  end

  local function recordOf(value: unknown): Record?
    for _, record in ipairs(records) do
      if record.tag == value then
        return record
      end
    end
    return nil
  end

  local function find(_self: tags.Service, name: string): tags.Tag?
    for _, record in ipairs(records) do
      if record.tag.name == name then
        return record.tag
      end
    end
    return nil
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
    local layout: overrides.Stack<string?>
    selection = overrides.new(context, settings.selected == true, function(): ()
      if created.dead then
        return
      end
      local value: boolean = selection:value()
      if created.selected ~= value then
        created.selected = value
        notify(created, 'selection')
      end
    end)
    layout = overrides.new(context, settings.layout, function(): ()
      if created.dead then
        return
      end
      local value: string? = layout:value()
      if created.layout ~= value then
        created.layout = value
        notify(created, 'layout')
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
      for _, effect in ipairs(layout:clear()) do
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
      local index = table.find(records, record)
      if index then
        table.remove(records, index)
      end
      local ok, failure = pcall(disposeAll, ended)
      notify(created, 'destroyed')
      if not ok then
        error(failure, 0)
      end
      return true
    end

    created = {
      name = name,
      index = settings.index or (#records + 1),
      selected = settings.selected == true,
      layout = settings.layout,
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
      exclude = function(_self: tags.Tag, caller: Owner, exclusion: tags.Exclusion): plugin.Effect
        context:checkOwner(caller)
        if type(exclusion) ~= 'table' then
          error('tags exclude: an exclusion is a table of fields, not a ' .. type(exclusion), 2)
        end
        plugin.rejectUnknownFields('tags exclude', exclusion, EXCLUSION_KEYS, 'panel', 2)
        local panel = exclusion.panel
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
      setSelected = function(_self: tags.Tag, caller: Owner, wanted: tags.Selection): boolean
        context:checkOwner(caller)
        if type(wanted) ~= 'table' or type(wanted.selected) ~= 'boolean' then
          error('tags setSelected: a selection is a table whose selected is a boolean', 2)
        end
        if created.dead then
          return false
        end
        if not selection:set(caller, wanted.selected) then
          return false
        end
        created.selected = selection:value()
        notify(created, 'selection')
        return true
      end,
      setLayout = function(_self: tags.Tag, caller: Owner, wanted: tags.LayoutChoice): boolean
        context:checkOwner(caller)
        if type(wanted) ~= 'table' then
          error('tags setLayout: a layout choice is a table of fields, not a ' .. type(wanted), 2)
        end
        plugin.rejectUnknownFields('tags setLayout', wanted, LAYOUT_KEYS, 'layout', 2)
        if wanted.layout ~= nil and type(wanted.layout) ~= 'string' then
          error('tags setLayout: layout is a layout name, not a ' .. type(wanted.layout), 2)
        end
        if created.dead then
          return false
        end
        if not layout:set(caller, wanted.layout) then
          return false
        end
        created.layout = layout:value()
        notify(created, 'layout')
        return true
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
            { index = created.index, selected = created.selected, layout = created.layout or '' }
          )
        end
        for target, owners in pairs(holds) do
          local details = surfaceDetails(target)
          details.excluded = next(exclusions[target] or {}) ~= nil
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
        for target, owners in pairs(exclusions) do
          local details = surfaceDetails(target)
          for caller in pairs(owners) do
            result[#result + 1] = inspection.registration(
              'exclusion',
              'tags.exclude',
              caller,
              name,
              not created.dead and context:owns(caller),
              details
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
        for _, entry in ipairs(layout:inspect()) do
          result[#result + 1] = inspection.registration(
            'layoutChoice',
            'tags.setLayout',
            entry.owner,
            name,
            not created.dead and context:owns(entry.owner),
            { layout = entry.value or '', cleared = entry.value == nil, current = entry.current }
          )
        end
        return result
      end,
    }
    records[#records + 1] = record
    notify(created, 'created')
    return record
  end

  -- A hold keeps the tag alive until its last holder releases it.
  local function hold(_self: tags.Service, caller: Owner, wanted: tags.Hold): (tags.Tag, plugin.Effect)
    context:checkOwner(caller)
    if type(wanted) ~= 'table' then
      error('tags hold: a hold is a table of fields, not a ' .. type(wanted), 2)
    end
    plugin.rejectUnknownFields('tags hold', wanted, HOLD_KEYS, 'name, index, selected, and layout', 2)
    local name = wanted.name
    if type(name) ~= 'string' or name == '' then
      error('tags hold: name is a non-empty tag name, not ' .. tostring(name), 2)
    end
    checkOptions('tags hold', wanted)
    local existing: Record? = nil
    for _, record in ipairs(records) do
      if record.tag.name == name then
        existing = record
      end
    end
    local record = existing or make(name, wanted)
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
    for index, record in ipairs(records) do
      result[index] = record.tag
    end
    table.sort(result, function(a: tags.Tag, b: tags.Tag): boolean
      return if a.index == b.index then a.name < b.name else a.index < b.index
    end)
    return result
  end

  local function onChanged(_self: tags.Service, caller: Owner, listener: tags.ChangeListener): plugin.Effect
    if type(listener) ~= 'table' then
      error('tags onChanged: a listener is a table of fields, not a ' .. type(listener), 2)
    end
    plugin.rejectUnknownFields('tags onChanged', listener, LISTENER_KEYS, 'tag and run', 2)
    if type(listener.run) ~= 'function' then
      error('tags onChanged: run is a function, not a ' .. type(listener.run), 2)
    end
    local wanted = listener.tag
    if wanted ~= nil and not recordOf(wanted) then
      error('tags onChanged: tag is a live tag of this service', 2)
    end
    return heard:add(caller, { tag = wanted, run = listener.run }, if wanted then { tag = wanted.name } else nil)
  end

  local service: tags.Service = {
    inspect = function(_self: tags.Service): inspection.Snapshot
      local result = heard:inspect 'tags.onChanged'
      for _, record in ipairs(records) do
        for _, entry in ipairs(record.inspect()) do
          result[#result + 1] = entry
        end
      end
      return inspection.snapshot(result, { tags = #records })
    end,
    hold = hold,
    all = all,
    find = find,
    onChanged = onChanged,
  }
  context:effect(function(): () -> ()
    return function(): ()
      for _, record in ipairs(table.clone(records)) do
        record.destroy()
      end
      heard:clear()
    end
  end)
  return service
end

return create
