-- Composition: a list of plugin entries, the patches a configuration applies to it, and the start that
-- makes a runtime from it. Composing is pure: it validates and answers a new frozen list, defining and
-- enabling nothing.

local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'

local compose = {}

export type Definition = adapter.Definition<any>
export type Config = { [string]: any }

-- One plugin of a composition: exactly one of `definition` and `factory`. A factory is called once per
-- start, so its definition can keep state across its own provider outages.
export type Entry = {
  read id: string,
  read definition: Definition?,
  read factory: (() -> Definition)?,
  read config: Config?,
}

-- A change to an entry list. A patch with `id` disables, replaces, or merges `config` into that entry; a
-- patch with `insert` adds an entry at the end, or `before` or `after` the one it names.
export type Patch = {
  read id: string?,
  read disabled: boolean?,
  read definition: Definition?,
  read factory: (() -> Definition)?,
  read config: Config?,
  read insert: Entry?,
  read before: string?,
  read after: string?,
}

-- A started composition: its runtime, and the instance made for each entry, by id.
export type Running = {
  read runtime: adapter.Runtime,
  read instances: { read [string]: adapter.Instance<any> },
}

type Raw = { [unknown]: unknown }

local ENTRY_KEYS: { [string]: boolean } = { id = true, definition = true, factory = true, config = true }
local PATCH_KEYS: { [string]: boolean } = {
  id = true,
  disabled = true,
  definition = true,
  factory = true,
  config = true,
  insert = true,
  before = true,
  after = true,
}

local function fail(message: string): never
  error('compose: ' .. message, 0)
end

local function frozenCopy(value: unknown): unknown
  if type(value) ~= 'table' or getmetatable(value :: any) ~= nil then
    return value
  end
  local copy: Raw = {}
  for key, item in value :: Raw do
    copy[key] = frozenCopy(item)
  end
  return table.freeze(copy)
end

local function checkSource(what: string, definition: unknown, factory: unknown): ()
  if definition ~= nil and factory ~= nil then
    fail(what .. ' gives both a definition and a factory; it gives one')
  end
  if definition ~= nil and type(definition) ~= 'table' then
    fail(what .. ': definition is a plugin definition, not a ' .. type(definition))
  end
  if factory ~= nil and type(factory) ~= 'function' then
    fail(what .. ': factory is a function, not a ' .. type(factory))
  end
end

local function checkConfig(what: string, config: unknown): ()
  if config ~= nil and type(config) ~= 'table' then
    fail(what .. ': config is a table of options, not a ' .. type(config))
  end
end

-- Answers a validated, frozen copy of an entry.
local function checkedEntry(value: unknown, position: string): Entry
  if type(value) ~= 'table' then
    fail(position .. ' is a table of fields, not a ' .. type(value))
  end
  local raw = value :: Raw
  local id = raw.id
  if type(id) ~= 'string' or id == '' then
    fail(position .. ': id is a non-empty string, not ' .. tostring(id))
  end
  local what = 'entry ' .. (id :: string)
  options.rejectUnknownFields('compose: ' .. what, raw, ENTRY_KEYS, 'id, definition, factory, and config', 0)
  checkSource(what, raw.definition, raw.factory)
  if raw.definition == nil and raw.factory == nil then
    fail(what .. ' gives neither a definition nor a factory')
  end
  checkConfig(what, raw.config)
  return table.freeze {
    id = id :: string,
    definition = raw.definition :: Definition?,
    factory = raw.factory :: (() -> Definition)?,
    config = frozenCopy(raw.config) :: Config?,
  }
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

local function idsOf(entries: { Entry }): string
  local ids: { string } = {}
  for index, entry in ipairs(entries) do
    ids[index] = entry.id
  end
  return table.concat(ids, ', ')
end

local function indexOf(entries: { Entry }, id: string): number?
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
  definition: Definition?,
  factory: (() -> Definition)?,
  config: Config?,
}

-- Checks a patch with an id and answers its fields.
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
  checkSource(what, raw.definition, raw.factory)
  checkConfig(what, raw.config)
  local changes = raw.definition ~= nil or raw.factory ~= nil or raw.config ~= nil
  if disabled and changes then
    fail(what .. ' disables the entry and also changes it; a disabled entry has nothing to change')
  end
  if not disabled and not changes then
    fail(what .. ' changes nothing; it gives disabled, definition, factory, or config')
  end
  return {
    id = id :: string,
    disabled = disabled == true,
    definition = raw.definition :: Definition?,
    factory = raw.factory :: (() -> Definition)?,
    config = raw.config :: Config?,
  }
end

local function patched(entry: Entry, patch: Keyed): Entry
  local definition, factory = entry.definition, entry.factory
  if patch.definition ~= nil or patch.factory ~= nil then
    definition, factory = patch.definition, patch.factory
  end
  local config = entry.config
  if patch.config ~= nil then
    config = options.merge { base = entry.config, over = patch.config }
  end
  return checkedEntry({ id = entry.id, definition = definition, factory = factory, config = config }, 'entry')
end

-- Answers the entries with the patches applied, frozen, raising with the id for a malformed entry or patch,
-- a duplicate id, a patch naming no entry, or one that both disables and changes an entry.
function compose.apply(entries: { Entry }, patches: { Patch }?): { Entry }
  local result: { Entry } = {}
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
    options.rejectUnknownFields(
      'compose: ' .. position,
      raw,
      PATCH_KEYS,
      'id, disabled, definition, factory, config, insert, before, and after',
      0
    )
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
  return table.freeze(result)
end

-- Makes a runtime, enables every entry in order, and drains it. A failure closes the runtime and is raised;
-- an entry's configuration error is that instance's load failure.
function compose.start(entries: { Entry }): Running
  local checked = compose.apply(entries)
  local runtime = adapter.runtime()
  local instances: { [string]: adapter.Instance<any> } = {}
  local ok, failure = pcall(function(): ()
    for _, entry in ipairs(checked) do
      local factory = entry.factory
      local definition = entry.definition or (factory and factory())
      if type(definition) ~= 'table' then
        error('compose: the factory of ' .. entry.id .. ' answered a ' .. type(definition) .. ', not a definition', 0)
      end
      local instance = runtime:use(definition, entry.config or {})
      instances[entry.id] = instance
      instance:enable()
    end
    runtime:drain()
  end)
  if not ok then
    runtime:close()
    error(failure, 0)
  end
  return table.freeze { runtime = runtime, instances = table.freeze(instances) }
end

return compose
