-- Named groups of borrowed panels, scoped to one provider activation.
--
-- Every change a caller makes to a tag is an effect of that caller's owner.
-- A membership is held by the owners that added it, and the panel stays a
-- member while any holder remains. A selection is an override: each owner
-- holds at most one per tag, the most recent live override decides the tag's
-- selection, and a tag with none falls back to the selection it was created
-- with. An owner that unloads therefore takes back its memberships and its
-- overrides, and leaves those of other owners as they were.

local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'

type Panel = tags.Panel
type Owner = tags.Owner

type Selection = { owner: Owner, value: boolean, effect: plugin.Effect? }

type Mutable = {
  name: string,
  index: number,
  dead: boolean,
  selected: boolean,
  layout: (({ Panel }) -> ())?,
  members: { Panel },
  add: (tags.Tag, Owner, Panel) -> boolean,
  remove: (tags.Tag, Owner, Panel) -> boolean,
  has: (tags.Tag, Panel) -> boolean,
  panels: (tags.Tag) -> { Panel },
  setSelected: (tags.Tag, Owner, tags.Selection) -> boolean,
  apply: (tags.Tag) -> boolean,
  destroy: (tags.Tag) -> boolean,
}

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

local function create(context: plugin.Context): tags.Service
  local registry: { tags.Tag } = {}
  local function all(_self: tags.Service): { tags.Tag }
    local result = table.clone(registry)
    table.sort(result, function(a: tags.Tag, b: tags.Tag): boolean
      return if a.index == b.index then a.name < b.name else a.index < b.index
    end)
    return result
  end
  local function find(_self: tags.Service, name: string): tags.Tag?
    for _, entry in ipairs(registry) do
      if entry.name == name then
        return entry
      end
    end
    return nil
  end
  local function new(self: tags.Service, owner: Owner, name: string, options: tags.Options?): tags.Tag
    context:checkOwner(owner)
    if type(name) ~= 'string' then
      error 'tags: a tag name must be a string'
    end
    if self:find(name) then
      error('tags: duplicate tag name ' .. name)
    end
    local settings: tags.Options = options or {}
    local initial = settings.selected == true
    local created: Mutable
    local cleanupEffect: plugin.Effect?
    -- Each member's holders, keyed by owner, with the effect each holds it by.
    local holds: { [Panel]: { [Owner]: plugin.Effect } } = {}
    local selections: { Selection } = {}

    local function forget(panel: Panel): ()
      holds[panel] = nil
      local index = table.find(created.members, panel)
      if index then
        table.remove(created.members, index)
      end
    end
    -- Releases the holds on members whose panels have died, so an owner does
    -- not keep one effect per panel it ever tagged.
    local function prune(): ()
      local ended: { plugin.Effect } = {}
      for index = #created.members, 1, -1 do
        local panel = created.members[index]
        if panel.dead then
          for _, effect in pairs(holds[panel] or {}) do
            ended[#ended + 1] = effect
          end
          forget(panel)
        end
      end
      disposeAll(ended)
    end
    local function members(_self: tags.Tag): { Panel }
      prune()
      return table.clone(created.members)
    end
    local function settle(): boolean
      local top = selections[#selections]
      local value = if top then top.value else initial
      if created.selected == value then
        return false
      end
      created.selected = value
      return true
    end
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
      for _, selection in ipairs(selections) do
        local effect = selection.effect
        if effect then
          ended[#ended + 1] = effect
        end
      end
      table.clear(holds)
      table.clear(selections)
      table.clear(created.members)
      local index = table.find(registry, created)
      if index then
        table.remove(registry, index)
      end
      disposeAll(ended)
      return true
    end
    local function destroy(_self: tags.Tag): boolean
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
    created = {
      name = name,
      index = settings.index or (#registry + 1),
      selected = initial,
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
          local current = holds[panel]
          if not current then
            current = {}
            holds[panel] = current
            table.insert(created.members, panel)
          end
          return function(): ()
            local remaining = holds[panel]
            if not remaining then
              return
            end
            remaining[caller] = nil
            if next(remaining) == nil then
              forget(panel)
            end
          end
        end)
        local current = holds[panel]
        if current then
          current[caller] = effect
        end
        return true
      end,
      -- An owner removes its own hold. The tag's owner removes every hold, as
      -- the tag is its own state; any other owner cannot remove a membership
      -- it does not hold.
      remove = function(_self: tags.Tag, caller: Owner, panel: Panel): boolean
        context:checkOwner(caller)
        local holders = holds[panel]
        if not holders then
          return false
        end
        if caller ~= owner then
          local held = holders[caller]
          if not held then
            error("tags: the tag '" .. name .. "' holds that panel for another owner", 2)
          end
          held:dispose()
          return true
        end
        local ended: { plugin.Effect } = {}
        for _, effect in pairs(holders) do
          ended[#ended + 1] = effect
        end
        forget(panel)
        disposeAll(ended)
        return true
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
        local selected = wanted.selected
        if created.dead then
          return false
        end
        for index, selection in ipairs(selections) do
          if selection.owner == caller then
            table.remove(selections, index)
            selection.value = selected
            selections[#selections + 1] = selection
            return settle()
          end
        end
        local selection: Selection = { owner = caller, value = selected, effect = nil }
        selection.effect = context:acquire(caller, function(): () -> ()
          selections[#selections + 1] = selection
          return function(): ()
            local index = table.find(selections, selection)
            if index then
              table.remove(selections, index)
              settle()
            end
          end
        end)
        return settle()
      end,
      apply = function(self: tags.Tag): boolean
        local layout = created.layout
        if created.dead or not created.selected or not layout then
          return false
        end
        layout(members(self))
        return true
      end,
      destroy = destroy,
    }
    local acquired = owner:effect(function(): () -> ()
      table.insert(registry, created)
      return function(): ()
        cleanupEffect = nil
        destroyRaw()
      end
    end)
    if created.dead then
      acquired:dispose()
    else
      cleanupEffect = acquired
    end
    return created
  end
  local function panelsOf(_self: tags.Service, target: tags.Target): { Panel }
    for _, entry in ipairs(registry) do
      if entry == target then
        return entry:panels()
      end
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
  local service: tags.Service = {
    new = new,
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
    only = function(self: tags.Service, owner: Owner, chosen: tags.Tag): ()
      for _, entry in ipairs(self:all()) do
        entry:setSelected(owner, { selected = entry == chosen })
      end
    end,
    isTag = function(_self: tags.Service, value: unknown): boolean
      for _, entry in ipairs(registry) do
        if entry == value then
          return true
        end
      end
      return false
    end,
    panelsOf = panelsOf,
  }
  context:effect(function(): () -> ()
    return function(): ()
      for _, entry in ipairs(table.clone(registry)) do
        entry:destroy()
      end
    end
  end)
  return service
end

return create
