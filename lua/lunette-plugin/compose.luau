-- Composition validates plugin entries and patches before a runtime starts.

local adapter = require '@lunette-plugin/adapter'
local options = require '@lunette-plugin/options'
local schemaRuntime = require '@lunette-plugin/schema/runtime'

local compose = {}

export type Definition = adapter.Definition<any>
export type Config = { [string]: any }

-- Each entry has one definition source. A factory runs once per start, preserving its definition across provider outages.
export type Entry = {
  read id: string,
  read definition: Definition?,
  read factory: (() -> Definition)?,
  read config: Config?,
}

-- An `id` patch disables or updates an entry. An `insert` patch appends an entry or places it before or after another entry.
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

export type ResolvedEntry = {
  read definition: Definition,
  read config: Config,
}

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

-- Deferred factories need detached structural values and the original identities of opaque values.
local originals: { [Raw]: Raw } = setmetatable({}, { __mode = 'k' }) :: any
local layers: { [Config]: { Config } } = setmetatable({}, { __mode = 'k' }) :: any

local function unwrapped(metadata: schemaRuntime.Node?): schemaRuntime.Node?
  local node = metadata
  while node and (node.kind == 'default' or node.kind == 'optional' or node.kind == 'refine') do
    node = node.child
  end
  return node
end

local frozenCopy: (unknown, schemaRuntime.Node?, { [Raw]: { [unknown]: Raw } }?) -> unknown

local function selected(value: unknown, metadata: schemaRuntime.Node?): schemaRuntime.Node?
  local node = unwrapped(metadata)
  if node and node.kind == 'union' then
    for _, alternative in node.alternatives or {} do
      local restored = frozenCopy(value, alternative)
      if pcall(schemaRuntime.parse, alternative, restored, 'compose configuration') then
        return selected(value, alternative)
      end
    end
  end
  return node
end

frozenCopy = function(value: unknown, metadata: schemaRuntime.Node?, seen: { [Raw]: { [unknown]: Raw } }?): unknown
  local node = selected(value, metadata)
  if node and (node.kind == 'custom' or node.kind == 'callback') then
    return if type(value) == 'table' then originals[value :: Raw] or value else value
  end
  if type(value) ~= 'table' or getmetatable(value :: any) ~= nil then
    return value
  end
  local raw = value :: Raw
  local copied = seen or {}
  local interpretations: { [unknown]: Raw } = copied[raw] or {}
  local shape: unknown = node or false
  local known = interpretations[shape]
  if known then
    return known
  end
  local copy: Raw = {}
  copied[raw] = interpretations
  interpretations[shape] = copy
  originals[copy] = originals[raw] or raw
  for key, item in raw do
    local child = if node
        and node.kind == 'object'
        and node.fields
        and type(key) == 'string'
      then node.fields[key]
      elseif node and (node.kind == 'array' or node.kind == 'map') then node.child
      else nil
    copy[key] = frozenCopy(item, child, copied)
  end
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

local function legacyMerged(base: Raw, over: Raw, seen: { [Raw]: { [Raw]: Raw } }?): Raw
  local copied = seen or {}
  local previous: { [Raw]: Raw } = copied[base] or {}
  local known = previous[over]
  if known then
    return known
  end
  local result = table.clone(base)
  copied[base] = previous
  previous[over] = result
  for key, value in over do
    local prior = result[key]
    result[key] = if options.isRecord(prior) and options.isRecord(value)
      then legacyMerged(prior :: Raw, value :: Raw, copied)
      else value
  end
  return result
end

local function configuration(value: Config?, metadata: schemaRuntime.Node?): Config?
  if value == nil then
    return nil
  end
  local pending = layers[value]
  if pending and metadata then
    local result: unknown = nil
    for _, layer in pending do
      -- A reused composed patch resolves its own layers before merging with this destination.
      local snapshot = configuration(layer, metadata)
      result = schemaMerged(result, snapshot, metadata)
    end
    return frozenCopy(result, metadata) :: Config
  end
  local snapshot = frozenCopy(value, metadata) :: Config
  if pending then
    layers[snapshot] = pending
  end
  return snapshot
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
  local definition = raw.definition :: Definition?
  return table.freeze {
    id = id :: string,
    definition = definition,
    factory = raw.factory :: (() -> Definition)?,
    config = configuration(raw.config :: Config?, if definition then definition.schema else nil),
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
  local metadata = if definition then definition.schema else nil
  local config = configuration(entry.config, metadata)
  if patch.config ~= nil then
    local over = configuration(patch.config, metadata) :: Config
    if metadata then
      config = frozenCopy(schemaMerged(config, over, metadata), metadata) :: Config
    else
      local pending = if config then layers[config] else nil
      local merged = frozenCopy(legacyMerged((config or {}) :: Raw, over :: Raw)) :: Config
      if factory then
        local sequence = if pending then table.clone(pending) else {}
        if not pending and config then
          table.insert(sequence, config)
        end
        table.insert(sequence, over)
        layers[merged] = table.freeze(sequence)
      end
      config = merged
    end
  end
  return checkedEntry({ id = entry.id, definition = definition, factory = factory, config = config }, 'entry')
end

-- Returns the patched entries in order. It rejects duplicate ids, missing patch targets, and patches that disable and update one entry.
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

-- The returned function accepts the definition's configuration type. A factory runs once to obtain the entry name.
function compose.configure<C>(target: adapter.Definition<C> | () -> adapter.Definition<C>): (C) -> Patch
  local definition: unknown = if type(target) == 'function' then target() else target
  local name = type(definition) == 'table' and (definition :: Raw).name
  if type(name) ~= 'string' then
    error('compose: configure takes a plugin definition or a factory of one, not a ' .. type(target), 2)
  end
  return function(config: C): Patch
    return { id = name :: string, config = config :: any }
  end
end

-- The target supplies the configuration type; the entry id supplies the patch target. This never calls a factory.
function compose.configureEntry<C>(id: string, target: adapter.Definition<C> | () -> adapter.Definition<C>): (C) -> Patch
  if type(id) ~= 'string' or id == '' then
    error('compose: configureEntry: id is a non-empty string, not ' .. tostring(id), 2)
  end
  if type(target) ~= 'function' and (type(target) ~= 'table' or type((target :: Raw).name) ~= 'string') then
    error('compose: configureEntry takes a plugin definition or a factory of one, not a ' .. type(target), 2)
  end
  return function(config: C): Patch
    return { id = id, config = config :: any }
  end
end

-- Resolves one checked entry's source and deferred configuration once per start, without initializing or validating settings.
function compose.resolveEntry(entry: Entry): ResolvedEntry
  local factory = entry.factory
  local definition = entry.definition or (factory and factory())
  if type(definition) ~= 'table' then
    error('compose: the factory of ' .. entry.id .. ' answered a ' .. type(definition) .. ', not a definition', 0)
  end
  local snapshot = configuration(entry.config, definition.schema)
  local config: Config
  if snapshot then
    config = snapshot
  else
    local empty: Config = {}
    config = table.freeze(empty)
  end
  return table.freeze { definition = definition, config = config }
end

-- Starts entries in order and drains the runtime. A failure closes the runtime; configuration errors remain instance load failures.
function compose.start(entries: { Entry }): Running
  local checked = compose.apply(entries)
  local runtime = adapter.runtime()
  local instances: { [string]: adapter.Instance<any> } = {}
  local ok, failure = pcall(function(): ()
    for _, entry in ipairs(checked) do
      local resolved = compose.resolveEntry(entry)
      local instance = runtime:use(resolved.definition, resolved.config)
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
