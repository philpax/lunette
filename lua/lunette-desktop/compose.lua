-- The desktop's entry list and the patches applied to it.
--
-- An entry is a definition, or a factory that makes one, under an id, with
-- the configuration it is used with. A patch names an entry by id and
-- disables it, replaces its definition, or merges configuration into it, or
-- it inserts a new entry. Composing is pure: it validates the list and the
-- patches and answers a new frozen list, and it neither defines nor enables
-- anything.

local plugin = require '@lunette-plugin'

local compose = {}

export type Definition = plugin.Definition<any>
export type Config = { [string]: any }

-- One plugin of the desktop. Exactly one of `definition` and `factory` is
-- given; a factory is called once for each runtime the desktop starts, so the
-- definition it makes can keep state across its own provider outages.
export type Entry = {
  read id: string,
  read definition: Definition?,
  read factory: (() -> Definition)?,
  read config: Config?,
}

-- A change to the entry list. A patch with `id` changes that entry: `disabled`
-- removes it, `definition` or `factory` replaces what it is made from, and
-- `config` is merged into its configuration. A patch with `insert` adds an
-- entry and carries nothing else.
export type Patch = {
  read id: string?,
  read disabled: boolean?,
  read definition: Definition?,
  read factory: (() -> Definition)?,
  read config: Config?,
  read insert: Entry?,
}

-- What `compose` takes: the entries to start from, by default the shipped
-- desktop's, and the patches to apply to them.
export type Options = {
  read entries: { Entry }?,
  read patches: { Patch }?,
}

type Raw = { [unknown]: unknown }

local OPTION_KEYS: { [string]: boolean } = { entries = true, patches = true }
local ENTRY_KEYS: { [string]: boolean } = { id = true, definition = true, factory = true, config = true }
local PATCH_KEYS: { [string]: boolean } = {
  id = true,
  disabled = true,
  definition = true,
  factory = true,
  config = true,
  insert = true,
}

local function fail(message: string): never
  error('desktop: ' .. message, 0)
end

local function rejectUnknown(raw: Raw, allowed: { [string]: boolean }, what: string, fields: string): ()
  for key, _ in raw do
    if type(key) ~= 'string' or not allowed[key] then
      fail(string.format('%s: unknown field %s; the fields are %s', what, tostring(key), fields))
    end
  end
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
  rejectUnknown(raw, ENTRY_KEYS, what, 'id, definition, factory, and config')
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
    config = plugin.merge { base = entry.config, over = patch.config }
  end
  return checkedEntry({ id = entry.id, definition = definition, factory = factory, config = config }, 'entry')
end

-- Answers the entries with the patches applied, as a frozen list of frozen
-- entries. Raises an error naming the id for a malformed entry or patch, two
-- entries or two patches with one id, a patch naming no entry, and a patch
-- that both disables and changes an entry.
function compose.apply(entries: { Entry }, options: Options?): { Entry }
  local given: Raw = {}
  if options ~= nil then
    if type(options) ~= 'table' then
      fail('the options are a table of fields, not a ' .. type(options))
    end
    given = (options :: unknown) :: Raw
    rejectUnknown(given, OPTION_KEYS, 'the options', 'entries and patches')
  end

  local result: { Entry } = {}
  for index, value in ipairs(checkedList(given.entries or entries, 'the entry list')) do
    local entry = checkedEntry(value, 'entry ' .. index)
    if indexOf(result, entry.id) then
      fail('two entries have the id ' .. entry.id)
    end
    result[#result + 1] = entry
  end

  local keyed: { Keyed } = {}
  local named: { [string]: boolean } = {}
  for index, value in ipairs(checkedList(given.patches or {}, 'the patch list')) do
    local position = 'patch ' .. index
    if type(value) ~= 'table' then
      fail(position .. ' is a table of fields, not a ' .. type(value))
    end
    local raw = value :: Raw
    rejectUnknown(raw, PATCH_KEYS, position, 'id, disabled, definition, factory, config, and insert')
    if raw.insert ~= nil then
      for key, _ in raw do
        if key ~= 'insert' then
          fail(position .. ' inserts an entry and also gives ' .. tostring(key) .. '; an insert carries nothing else')
        end
      end
      local entry = checkedEntry(raw.insert, 'the entry ' .. position .. ' inserts')
      if indexOf(result, entry.id) then
        fail('the insert of ' .. entry.id .. ' names an entry that already exists; patch it by its id instead')
      end
      result[#result + 1] = entry
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

return compose
