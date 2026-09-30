-- Named groups of borrowed panels, scoped to one provider activation.

local plugin = require '@lunette-plugin'
local tags = require '@lunette-contracts/tags'

type Mutable = {
  name: string,
  index: number,
  dead: boolean,
  selected: boolean,
  layout: (({ tags.Panel }) -> ())?,
  members: { tags.Panel & { read dead: boolean } },
  add: (tags.Tag, tags.Panel) -> boolean,
  remove: (tags.Tag, tags.Panel) -> boolean,
  has: (tags.Tag, tags.Panel) -> boolean,
  panels: (tags.Tag) -> { tags.Panel },
  setSelected: (tags.Tag, boolean) -> boolean,
  apply: (tags.Tag) -> boolean,
  destroy: (tags.Tag) -> boolean,
}

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
  local function new(self: tags.Service, owner: tags.Owner, name: string, options: tags.Options?): tags.Tag
    context:checkOwner(owner)
    if type(name) ~= 'string' then
      error 'tags: a tag name must be a string'
    end
    if self:find(name) then
      error('tags: duplicate tag name ' .. name)
    end
    local settings: tags.Options = options or {}
    local created: Mutable
    local cleanupEffect: plugin.Effect?
    local function members(_self: tags.Tag): { tags.Panel }
      for index = #created.members, 1, -1 do
        if created.members[index].dead then
          table.remove(created.members, index)
        end
      end
      return table.clone(created.members)
    end
    local function destroyRaw(): boolean
      if created.dead then
        return false
      end
      created.dead = true
      table.clear(created.members)
      local index = table.find(registry, created)
      if index then
        table.remove(registry, index)
      end
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
      selected = settings.selected == true,
      layout = settings.layout,
      dead = false,
      members = {},
      add = function(_self: tags.Tag, panel: tags.Panel): boolean
        if created.dead or panel.dead or table.find(created.members, panel) then
          return false
        end
        table.insert(created.members, panel)
        return true
      end,
      remove = function(_self: tags.Tag, panel: tags.Panel): boolean
        local index = table.find(created.members, panel)
        if not index then
          return false
        end
        table.remove(created.members, index)
        return true
      end,
      has = function(self: tags.Tag, panel: tags.Panel): boolean
        return table.find(members(self), panel) ~= nil
      end,
      panels = members,
      setSelected = function(_self: tags.Tag, selected: boolean): boolean
        if created.dead or created.selected == selected then
          return false
        end
        created.selected = selected
        return true
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
  local function panelsOf(_self: tags.Service, target: tags.Target): { tags.Panel }
    for _, entry in ipairs(registry) do
      if entry == target then
        return entry:panels()
      end
    end
    local classified: tags.Tag | { read panels: nil, read [number]: tags.Tag | tags.Panel } = target
    if classified.panels then
      return classified:panels()
    end
    local view = classified
    local result: { tags.Panel } = {}
    local seen: { [tags.Panel]: boolean } = {}
    local holdsTags: boolean? = nil
    for index = 1, #view do
      local item: tags.Tag | (tags.Panel & { read panels: nil }) = view[index]
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
    only = function(self: tags.Service, chosen: tags.Tag): ()
      for _, entry in ipairs(self:all()) do
        entry:setSelected(entry == chosen)
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
