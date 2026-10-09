-- Composition validates plugin entries and patches before a runtime starts.

local adapter = require '@lunette-plugin/adapter'
local fields = require '@lunette-plugin/fields'
local schemaRuntime = require '@lunette-plugin/schema/runtime'

local compose = {}

export type Definition = adapter.Definition<any>
export type Config = { [string]: any }

-- A definition, or a factory of one. Composition calls a factory to read its schema and again on each start, so a
-- factory has no side effects until its definition activates.
export type Source = Definition | () -> Definition

export type Entry = {
  read id: string,
  read definition: Source,
  read config: Config?,
}

-- A keyed patch disables an entry, replaces its definition, or merges configuration into it. A configuration patch
-- may name the definition it expects as `target`. An insert patch appends an entry or places it before or after
-- another entry.
export type Patch =
  { read id: string, read disabled: true }
  | { read id: string, read definition: Source, read config: Config? }
  | { read id: string, read config: Config, read target: Source? }
  | { read insert: Entry, read before: string? }
  | { read insert: Entry, read after: string? }

export type ResolvedEntry = {
  read definition: Definition,
  read config: Config,
}

type Raw = { [unknown]: unknown }

type Settled = {
  read id: string,
  read definition: Source,
  read config: Config?,
}

local ENTRY_KEYS: { string } = { 'id', 'definition', 'config' }
local PATCH_KEYS: { string } = { 'id', 'disabled', 'definition', 'config', 'target', 'insert', 'before', 'after' }

local function fail(message: string): never
  error('compose: ' .. message, 0)
end

local function unwrapped(metadata: schemaRuntime.Node?): schemaRuntime.Node?
  local node = metadata
  while node and (node.kind == 'default' or node.kind == 'optional' or node.kind == 'refine') do
    node = node.child
  end
  return node
end

local frozenCopy: (unknown, schemaRuntime.Node?, { [Raw]: boolean }?) -> unknown

-- A union copies by the first alternative that parses the value. When none does, resolution reports the problem.
local function selected(value: unknown, metadata: schemaRuntime.Node?): schemaRuntime.Node?
  local node = unwrapped(metadata)
  if node and node.kind == 'union' then
    for _, alternative in node.alternatives or {} do
      if pcall(schemaRuntime.parse, alternative, value, 'compose configuration') then
        return selected(value, alternative)
      end
    end
  end
  return node
end

-- Custom and callback values keep their identity. Every other plain table is copied and frozen.
frozenCopy = function(value: unknown, metadata: schemaRuntime.Node?, visiting: { [Raw]: boolean }?): unknown
  local node = selected(value, metadata)
  if node and (node.kind == 'custom' or node.kind == 'callback') then
    return value
  end
  if type(value) ~= 'table' or getmetatable(value :: any) ~= nil then
    return value
  end
  local raw = value :: Raw
  local active = visiting or {}
  if active[raw] then
    fail 'configuration contains a recursive table'
  end
  active[raw] = true
  local copy: Raw = {}
  for key, item in raw do
    local child = if node
        and node.kind == 'object'
        and node.fields
        and type(key) == 'string'
      then node.fields[key]
      elseif node and (node.kind == 'array' or node.kind == 'map') then node.child
      else nil
    copy[key] = frozenCopy(item, child, active)
  end
  active[raw] = nil
  return table.freeze(copy)
end

local function schemaMerged(base: unknown, over: unknown, metadata: schemaRuntime.Node): unknown
  local node = unwrapped(metadata)
  if not node or node.merge ~= 'object' or type(over) ~= 'table' or getmetatable(over :: any) ~= nil then
    return over
  end
  local result: Raw = if type(base) == 'table' and getmetatable(base :: any) == nil
    then table.clone(base :: Raw)
    else {}
  for key, value in over :: Raw do
    local child = if node.fields and type(key) == 'string' then node.fields[key] else nil
    result[key] = if child then schemaMerged(result[key], value, child) else value
  end
  return result
end

local function checkSource(what: string, field: string, source: unknown): ()
  if source ~= nil and type(source) ~= 'function' and not adapter.isDefinition(source) then
    fail(what .. ': ' .. field .. ' is a plugin definition or a factory of one, not a ' .. type(source))
  end
end

local function sourced(id: string, source: Source): Definition
  if type(source) ~= 'function' then
    return source
  end
  local made: unknown = source()
  if not adapter.isDefinition(made) then
    fail('the factory of ' .. id .. ' answered a ' .. type(made) .. ', not a plugin definition')
  end
  return made :: Definition
end

local function settled(id: string, source: Source, config: unknown): Settled
  return table.freeze {
    id = id,
    definition = source,
    config = if config ~= nil then frozenCopy(config, sourced(id, source).schema) :: Config else nil,
  }
end

local function checkConfig(what: string, config: unknown): ()
  if config ~= nil and type(config) ~= 'table' then
    fail(what .. ': config is a table of options, not a ' .. type(config))
  end
end

local function checkedEntry(value: unknown, position: string): Settled
  if type(value) ~= 'table' then
    fail(position .. ' is a table of fields, not a ' .. type(value))
  end
  local raw = value :: Raw
  local id = raw.id
  if type(id) ~= 'string' or id == '' then
    fail(position .. ': id is a non-empty string, not ' .. tostring(id))
  end
  local what = 'entry ' .. (id :: string)
  fields.rejectUnknownFields('compose: ' .. what, raw, ENTRY_KEYS, 0)
  if raw.definition == nil then
    fail(what .. ' gives no definition')
  end
  checkSource(what, 'definition', raw.definition)
  checkConfig(what, raw.config)
  return settled(id :: string, raw.definition :: Source, raw.config)
end

local function checkedList(value: unknown, what: string): { unknown }
  if type(value) ~= 'table' then
    fail(what .. ' is a list, not a ' .. type(value))
  end
  local list = value :: Raw
  local count = rawlen(list :: any)
  for key, _ in list do
    if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > count then
      fail(what .. ' is a list, and ' .. tostring(key) .. ' is not one of its positions')
    end
  end
  for index = 1, count do
    if list[index] == nil then
      fail(what .. ' is a list, and position ' .. index .. ' is empty')
    end
  end
  return list :: { unknown }
end

local function idsOf(entries: { Settled }): string
  local ids: { string } = {}
  for index, entry in ipairs(entries) do
    ids[index] = entry.id
  end
  return table.concat(ids, ', ')
end

local function indexOf(entries: { Settled }, id: string): number?
  for index, entry in ipairs(entries) do
    if entry.id == id then
      return index
    end
  end
  return nil
end

type Keyed = {
  id: string,
  disabled: boolean,
  definition: Source?,
  config: Config?,
  target: Source?,
}

local function checkedKeyed(raw: Raw, position: string): Keyed
  local id = raw.id
  if type(id) ~= 'string' or id == '' then
    fail(position .. ' names an entry by a non-empty string id, not ' .. tostring(id))
  end
  local what = 'the patch for ' .. (id :: string)
  if raw.before ~= nil or raw.after ~= nil then
    fail(what .. ' gives before or after, which place an insert; ordering an existing entry is not a patch')
  end
  local disabled = raw.disabled
  if disabled ~= nil and disabled ~= true then
    fail(what .. ': disabled is true or absent, not ' .. tostring(disabled))
  end
  checkSource(what, 'definition', raw.definition)
  checkSource(what, 'target', raw.target)
  checkConfig(what, raw.config)
  local changes = raw.definition ~= nil or raw.config ~= nil
  if disabled and changes then
    fail(what .. ' disables the entry and also changes it; a disabled entry has nothing to change')
  end
  if not disabled and not changes then
    fail(what .. ' changes nothing; it gives disabled, definition, or config')
  end
  if raw.target ~= nil and (disabled or raw.definition ~= nil) then
    fail(what .. ' gives a target, which only a configuration patch checks')
  end
  return {
    id = id :: string,
    disabled = disabled == true,
    definition = raw.definition :: Source?,
    config = raw.config :: Config?,
    target = raw.target :: Source?,
  }
end

local function patched(entry: Settled, patch: Keyed): Settled
  if patch.target ~= nil and not rawequal(patch.target, entry.definition) then
    fail('the patch for ' .. entry.id .. ' targets another definition than the entry has')
  end
  local source = patch.definition or entry.definition
  local config: unknown = entry.config
  if patch.config ~= nil then
    -- Without a schema there is no merge rule, so the patch's configuration replaces the entry's.
    local metadata = sourced(entry.id, source).schema
    config = if metadata then schemaMerged(config, patch.config, metadata) else patch.config
  end
  return settled(entry.id, source, config)
end

-- Rejects duplicate ids, missing patch targets, and patches that both disable and update one entry.
function compose.apply(entries: { Entry }, patches: { Patch }?): { Entry }
  local result: { Settled } = {}
  for index, value in ipairs(checkedList(entries, 'the entry list')) do
    local entry = checkedEntry(value, 'entry ' .. index)
    if indexOf(result, entry.id) then
      fail('two entries have the id ' .. entry.id)
    end
    result[#result + 1] = entry
  end

  local keyed: { Keyed } = {}
  local named: { [string]: boolean } = {}
  for index, value in ipairs(checkedList(patches or {}, 'the patch list')) do
    local position = 'patch ' .. index
    if type(value) ~= 'table' then
      fail(position .. ' is a table of fields, not a ' .. type(value))
    end
    local raw = value :: Raw
    fields.rejectUnknownFields('compose: ' .. position, raw, PATCH_KEYS, 0)
    if raw.insert ~= nil then
      for key, _ in raw do
        if key ~= 'insert' and key ~= 'before' and key ~= 'after' then
          fail(
            position
              .. ' inserts an entry and also gives '
              .. tostring(key)
              .. '; an insert carries only before or after'
          )
        end
      end
      local entry = checkedEntry(raw.insert, 'the entry ' .. position .. ' inserts')
      if indexOf(result, entry.id) then
        fail('the insert of ' .. entry.id .. ' names an entry that already exists; patch it by its id instead')
      end
      local before, after = raw.before, raw.after
      if before ~= nil and after ~= nil then
        fail('the insert of ' .. entry.id .. ' gives both before and after; it gives one')
      end
      local anchor = before or after
      if anchor == nil then
        result[#result + 1] = entry
      else
        local field = if before ~= nil then 'before' else 'after'
        if type(anchor) ~= 'string' then
          fail('the insert of ' .. entry.id .. ': ' .. field .. ' is an entry id, not a ' .. type(anchor))
        end
        local at = indexOf(result, anchor :: string)
        if at == nil then
          fail(
            'the insert of '
              .. entry.id
              .. ' goes '
              .. field
              .. ' '
              .. tostring(anchor)
              .. ', which is not an entry; the entries are '
              .. idsOf(result)
          )
        end
        table.insert(result, if before ~= nil then at :: number else (at :: number) + 1, entry)
      end
    else
      local patch = checkedKeyed(raw, position)
      if named[patch.id] then
        fail('two patches name ' .. patch.id .. '; combine them into one')
      end
      named[patch.id] = true
      keyed[#keyed + 1] = patch
    end
  end

  for _, patch in ipairs(keyed) do
    local index = indexOf(result, patch.id)
    if index == nil then
      fail('a patch names ' .. patch.id .. ', which is not an entry; the entries are ' .. idsOf(result))
    elseif patch.disabled then
      table.remove(result, index)
    else
      result[index] = patched(result[index], patch)
    end
  end
  return (table.freeze(result) :: unknown) :: { Entry }
end

-- The target types the configuration, and composition checks it against the entry, so a factory is never called.
function compose.configure<C>(id: string, target: adapter.Definition<C> | () -> adapter.Definition<C>): (C) -> Patch
  if type(id) ~= 'string' or id == '' then
    error('compose: configure: id is a non-empty string, not ' .. tostring(id), 2)
  end
  if type(target) ~= 'function' and not adapter.isDefinition(target) then
    error('compose: configure takes a plugin definition or a factory of one, not a ' .. type(target), 2)
  end
  return function(config: C): Patch
    return { id = id, config = config :: any, target = target :: any }
  end
end

-- Answers a frozen copy of a configuration, interpreted by the schema so custom values keep their identity.
function compose.snapshot(config: unknown, metadata: schemaRuntime.Node?): unknown
  return frozenCopy(config, metadata)
end

local empty: Config = {}
local EMPTY = table.freeze(empty)

-- Calls the entry's factory but initializes and validates nothing.
function compose.resolveEntry(entry: Entry): ResolvedEntry
  local checked = (entry :: unknown) :: Settled
  return table.freeze {
    definition = sourced(checked.id, checked.definition),
    config = checked.config or EMPTY,
  }
end

return compose
