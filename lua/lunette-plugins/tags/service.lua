-- Named groups of borrowed panels, scoped to one provider activation.
--
-- Every change a caller makes to a tag is an effect of that caller's owner.
-- A membership is held by the owners that added it and an exclusion by the
-- owners that excluded it; a panel is a member while a membership remains
-- and no exclusion does. A selection and a layout are overrides: each owner
-- holds at most one of each per tag, and the most recent live override
-- decides. A tag made by new ends with its owner; a tag made by hold ends
-- when its last holder lets go. An owner that unloads therefore takes back
-- its memberships, exclusions, overrides, and holds, and leaves those of
-- other owners as they were.

local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'
local protected = require '@lunette-plugins/protected'
local overrides = require '@lunette-plugins/tags/overrides'

type Panel = tags.Panel
type Owner = tags.Owner

type Listener = {
  owner: Owner,
  tag: tags.Tag?,
  run: (tags.Change) -> (),
  active: boolean,
}

type Mutable = {
  name: string,
  index: number,
  dead: boolean,
  selected: boolean,
  layout: string?,
  members: { Panel },
  add: (tags.Tag, Owner, Panel) -> boolean,
  remove: (tags.Tag, Owner, Panel) -> boolean,
  exclude: (tags.Tag, Owner, tags.Exclusion) -> plugin.Effect,
  has: (tags.Tag, Panel) -> boolean,
  panels: (tags.Tag) -> { Panel },
  setSelected: (tags.Tag, Owner, tags.Selection) -> boolean,
  setLayout: (tags.Tag, Owner, tags.LayoutChoice) -> boolean,
  destroy: (tags.Tag, Owner) -> boolean,
}

-- What the registry keeps for a tag beside the tag itself: who may end it.
-- A tag new made has an owner; a tag hold made has holders and no owner.
type Record = {
  tag: tags.Tag,
  owner: Owner?,
  holders: { [Owner]: plugin.Effect },
  destroyRaw: () -> boolean,
  retire: () -> boolean,
}

local LISTENER_KEYS: { [string]: boolean } = { tag = true, run = true }
local HOLD_KEYS: { [string]: boolean } = { name = true, index = true, selected = true, layout = true }

-- Disposes every effect, attempting all before raising the first failure.
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

local function checkOptions(what: string, options: tags.Options): ()
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
  local listeners: { Listener } = {}

  local function notify(tag: tags.Tag, kind: tags.ChangeKind): ()
    local change: tags.Change = table.freeze { tag = tag, kind = kind }
    for _, listener in ipairs(table.clone(listeners)) do
      local wanted = listener.tag
      if listener.active and context:owns(listener.owner) and (wanted == nil or wanted == tag) then
        protected.call('tags: a change listener', function(): ()
          listener.run(change)
        end)
      end
    end
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

  -- Makes a tag and registers it. An owner makes a tag that ends with it; no
  -- owner makes a tag its holders keep.
  local function make(name: string, settings: tags.Options, tagOwner: Owner?): Record
    local created: Mutable
    local record: Record
    -- Each panel ever added and still held, in the order it was first held.
    local held: { Panel } = {}
    -- Each held panel's holders, keyed by owner, with the effect each holds
    -- it by; likewise each excluded panel's excluders.
    local holds: { [Panel]: { [Owner]: plugin.Effect } } = {}
    local exclusions: { [Panel]: { [Owner]: plugin.Effect } } = {}

    -- Recomputes the members from the holds and exclusions, and announces a
    -- change of them.
    local function settleMembers(): ()
      local members: { Panel } = {}
      for _, panel in ipairs(held) do
        if not panel.dead and next(exclusions[panel] or {}) == nil then
          members[#members + 1] = panel
        end
      end
      local changed = #members ~= #created.members
      if not changed then
        for index, panel in ipairs(members) do
          if created.members[index] ~= panel then
            changed = true
            break
          end
        end
      end
      created.members = members
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

    -- Releases the holds and exclusions of panels that have died, so an
    -- owner does not keep one effect per panel it ever tagged. A dead panel
    -- leaves without an announcement; panels:onRemoved announces it.
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
      for index = #created.members, 1, -1 do
        if created.members[index].dead then
          table.remove(created.members, index)
        end
      end
      disposeAll(ended)
    end

    local function members(_self: tags.Tag): { Panel }
      prune()
      return table.clone(created.members)
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

    local function destroyRaw(): boolean
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
      table.clear(created.members)
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

    local cleanupEffect: plugin.Effect?
    -- Ends the tag, through its owner's effect when it has one, so the owner
    -- no longer holds an effect for a tag that has ended.
    local function retire(): boolean
      if created.dead then
        return false
      end
      local effect = cleanupEffect
      if effect then
        effect:dispose()
        return true
      end
      return destroyRaw()
    end
    -- Only the owner that made a tag with new ends it. A tag made by hold has
    -- no owner, and ends when its last holder lets go.
    local function destroy(_self: tags.Tag, caller: Owner): boolean
      context:checkOwner(caller)
      if created.dead then
        return false
      end
      if tagOwner == nil then
        error("tags: the tag '" .. name .. "' is held, and ends when its last holder lets go", 2)
      end
      if caller ~= tagOwner then
        error("tags: only the owner that made the tag '" .. name .. "' destroys it", 2)
      end
      return retire()
    end

    created = {
      name = name,
      index = settings.index or (#records + 1),
      selected = settings.selected == true,
      layout = settings.layout,
      dead = false,
      members = {},
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
      -- An owner removes its own hold. The owner of a tag new made removes
      -- every hold, as the tag is its own state; any other owner cannot
      -- remove a membership it does not hold, and excludes the panel instead.
      remove = function(_self: tags.Tag, caller: Owner, panel: Panel): boolean
        context:checkOwner(caller)
        local holders = holds[panel]
        if not holders then
          return false
        end
        if caller ~= tagOwner then
          local mine = holders[caller]
          if not mine then
            error("tags: the tag '" .. name .. "' holds that panel for another owner; exclude it instead", 2)
          end
          mine:dispose()
          return true
        end
        local ended: { plugin.Effect } = {}
        for _, effect in pairs(holders) do
          ended[#ended + 1] = effect
        end
        forget(panel)
        settleMembers()
        disposeAll(ended)
        return true
      end,
      exclude = function(_self: tags.Tag, caller: Owner, exclusion: tags.Exclusion): plugin.Effect
        context:checkOwner(caller)
        if type(exclusion) ~= 'table' then
          error('tags exclude: an exclusion is a table of fields, not a ' .. type(exclusion), 2)
        end
        for key, _ in exclusion :: { [unknown]: unknown } do
          if key ~= 'panel' then
            error('tags exclude: unknown field ' .. tostring(key) .. '; the field is panel', 2)
          end
        end
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
        for key, _ in wanted :: { [unknown]: unknown } do
          if key ~= 'layout' then
            error('tags setLayout: unknown field ' .. tostring(key) .. '; the field is layout', 2)
          end
        end
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
      destroy = destroy,
    }
    local tag: tags.Tag = created
    record = { tag = tag, owner = tagOwner, holders = {}, destroyRaw = destroyRaw, retire = retire }
    records[#records + 1] = record
    if tagOwner then
      local ok, failure = pcall(function(): ()
        cleanupEffect = tagOwner:effect(function(): () -> ()
          return function(): ()
            cleanupEffect = nil
            destroyRaw()
          end
        end)
      end)
      if not ok then
        local index = table.find(records, record)
        if index then
          table.remove(records, index)
        end
        created.dead = true
        error(failure, 0)
      end
    end
    notify(created, 'created')
    return record
  end

  local function new(self: tags.Service, caller: Owner, name: string, options: tags.Options?): tags.Tag
    context:checkOwner(caller)
    if type(name) ~= 'string' then
      error('tags: a tag name must be a string', 2)
    end
    if self:find(name) then
      error('tags: duplicate tag name ' .. name, 2)
    end
    local settings: tags.Options = options or {}
    checkOptions('tags new', settings)
    return make(name, settings, caller).tag
  end

  -- Holds the named tag for the caller, making it when there is none. A tag
  -- new made is borrowed: the effect holds nothing, and the tag still ends
  -- with its owner.
  local function hold(_self: tags.Service, caller: Owner, wanted: tags.Hold): (tags.Tag, plugin.Effect)
    context:checkOwner(caller)
    if type(wanted) ~= 'table' then
      error('tags hold: a hold is a table of fields, not a ' .. type(wanted), 2)
    end
    for key, _ in wanted :: { [unknown]: unknown } do
      if type(key) ~= 'string' or not HOLD_KEYS[key] then
        error('tags hold: unknown field ' .. tostring(key) .. '; the fields are name, index, selected, and layout', 2)
      end
    end
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
    local record = existing or make(name, wanted, nil)
    if record.owner ~= nil then
      return record.tag, context:acquire(caller, function(): () -> ()
        return function(): () end
      end)
    end
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
          record.destroyRaw()
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

  local function panelsOf(_self: tags.Service, target: tags.Target): { Panel }
    local record = recordOf(target)
    if record then
      return record.tag:panels()
    end
    local classified: tags.Tag | { read panels: nil, read [number]: tags.Tag | Panel } = target
    if classified.panels then
      return classified:panels()
    end
    local view = classified
    local result: { Panel } = {}
    local seen: { [Panel]: boolean } = {}
    local holdsTags: boolean? = nil
    for index = 1, #view do
      local item: tags.Tag | (Panel & { read panels: nil }) = view[index]
      local isTag = item.panels ~= nil
      if holdsTags ~= nil and holdsTags ~= isTag then
        error 'tags: an array holds tags or panels, not both'
      end
      holdsTags = isTag
      if item.panels then
        for _, panel in ipairs(item:panels()) do
          if not seen[panel] then
            seen[panel] = true
            table.insert(result, panel)
          end
        end
      elseif not item.dead and not seen[item] then
        seen[item] = true
        table.insert(result, item)
      end
    end
    return result
  end

  local function onChanged(_self: tags.Service, caller: Owner, listener: tags.ChangeListener): plugin.Effect
    if type(listener) ~= 'table' then
      error('tags onChanged: a listener is a table of fields, not a ' .. type(listener), 2)
    end
    for key, _ in listener :: { [unknown]: unknown } do
      if type(key) ~= 'string' or not LISTENER_KEYS[key] then
        error('tags onChanged: unknown field ' .. tostring(key) .. '; the fields are tag and run', 2)
      end
    end
    if type(listener.run) ~= 'function' then
      error('tags onChanged: run is a function, not a ' .. type(listener.run), 2)
    end
    local wanted = listener.tag
    if wanted ~= nil and not recordOf(wanted) then
      error('tags onChanged: tag is a live tag of this service', 2)
    end
    local entry: Listener = { owner = caller, tag = wanted, run = listener.run, active = true }
    return context:acquire(caller, function(): () -> ()
      listeners[#listeners + 1] = entry
      return function(): ()
        entry.active = false
        local index = table.find(listeners, entry)
        if index then
          table.remove(listeners, index)
        end
      end
    end)
  end

  local service: tags.Service = {
    new = new,
    hold = hold,
    all = all,
    find = find,
    current = function(self: tags.Service): { tags.Tag }
      local result: { tags.Tag } = {}
      for _, entry in ipairs(self:all()) do
        if entry.selected then
          table.insert(result, entry)
        end
      end
      return result
    end,
    only = function(self: tags.Service, caller: Owner, chosen: tags.Tag): ()
      for _, entry in ipairs(self:all()) do
        entry:setSelected(caller, { selected = entry == chosen })
      end
    end,
    isTag = function(_self: tags.Service, value: unknown): boolean
      return recordOf(value) ~= nil
    end,
    panelsOf = panelsOf,
    onChanged = onChanged,
  }
  context:effect(function(): () -> ()
    return function(): ()
      for _, record in ipairs(table.clone(records)) do
        record.retire()
      end
      table.clear(listeners)
    end
  end)
  return service
end

return create
