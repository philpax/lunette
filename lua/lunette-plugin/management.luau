-- Owns session entries and previous-good configuration over one nontransactional plugin runtime.

local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local contract = require '@lunette-contracts/composition'
local lunette = require '@lunette'
local optionsModule = require '@lunette-plugin/options'
local schema = require '@lunette-plugin/schema'
local schemaRuntime = require '@lunette-plugin/schema/runtime'
local management = {}

export type Options = { read protected: { string }? }
export type Running = {
  read runtime: adapter.Runtime,
  read service: contract.Service,
}

type Raw = { [unknown]: unknown }
type Prepared = { read id: string, read definition: adapter.Definition<any>, read config: unknown }
type Record = {
  definition: adapter.Definition<any>,
  instance: adapter.Instance<any>,
  config: unknown,
  good: unknown,
  hasGood: boolean,
  previous: unknown,
  hasPrevious: boolean,
  recovering: boolean,
  removing: boolean,
}

local function fail(message: string): never
  error('composition: ' .. message, 0)
end

local function selected(value: unknown, metadata: schema.Metadata?): schema.Metadata?
  local node = metadata
  while node do
    if node.kind == 'default' or node.kind == 'optional' or node.kind == 'refine' then
      node = node.child
    elseif node.kind == 'union' then
      local matched: schema.Metadata? = nil
      for _, alternative in node.alternatives or {} do
        if pcall(schemaRuntime.parse, alternative, value, 'composition configuration') then
          matched = alternative
          break
        end
      end
      if not matched then
        schemaRuntime.parse(node, value, 'composition configuration')
      end
      node = matched
    else
      return node
    end
  end
  return nil
end

local function copied(value: unknown, metadata: schema.Metadata?, active: { [Raw]: boolean }?): unknown
  local node = selected(value, metadata)
  if node and (node.kind == 'custom' or node.kind == 'callback') then
    return value
  end
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    return value
  end
  local visiting = active or {}
  local raw = value :: Raw
  if visiting[raw] then
    fail 'configuration contains a recursive table'
  end
  visiting[raw] = true
  local result: Raw = {}
  for key, item in raw do
    local child: schema.Metadata? = nil
    if node then
      if node.kind == 'object' and node.fields and type(key) == 'string' then
        child = node.fields[key]
      elseif node.kind == 'array' or node.kind == 'map' then
        child = node.child
      end
    end
    result[key] = copied(item, child, visiting)
  end
  visiting[raw] = nil
  return table.freeze(result)
end

local function checkedEntries(entries: { compose.Entry }): { compose.Entry }
  if type(entries) ~= 'table' then
    fail 'the entry list is a table'
  end
  local sanitized: { compose.Entry } = {}
  local count = #entries
  for key, entry in (entries :: unknown) :: Raw do
    if type(key) ~= 'number' or key < 1 or key > count or key ~= math.floor(key) then
      fail('the entry list has an invalid position ' .. tostring(key))
    end
    if type(entry) ~= 'table' then
      fail('entry ' .. tostring(key) .. ' is a table')
    end
    local raw = entry :: Raw
    if raw.config ~= nil and type(raw.config) ~= 'table' then
      fail('entry ' .. tostring(raw.id) .. ': config is a table of options')
    end
    -- Preserve the config reference so resolveEntry can find deferred layers and recover opaque identities.
    local fields = table.clone(raw)
    fields.config = nil
    sanitized[key :: number] = (fields :: unknown) :: compose.Entry
  end
  local checked = compose.apply(sanitized)
  local result: { compose.Entry } = {}
  for index, entry in checked do
    result[index] = table.freeze {
      id = entry.id,
      definition = entry.definition,
      factory = entry.factory,
      config = entries[index].config,
    }
  end
  return result
end

local function preflight(definition: adapter.Definition<any>, config: unknown): unknown
  local metadata = definition.schema
  local snapshot = copied(config, metadata)
  local resolve = definition.resolve
  if resolve then
    resolve(snapshot)
  end
  return snapshot
end

local function checkedDefinition(id: string, value: unknown): adapter.Definition<any>
  local field = 'definition'
  if type(value) == 'table' and getmetatable(value) == nil then
    local raw = value :: Raw
    for _, name in { 'name', 'requires', 'provides', 'init', 'schema', 'resolve' } do
      local item = raw[name]
      local expected = if name == 'name'
        then 'string'
        elseif name == 'init' or name == 'resolve' then 'function'
        else 'table'
      if
        (item ~= nil or (name ~= 'schema' and name ~= 'resolve'))
        and (type(item) ~= expected or (name == 'name' and item == ''))
      then
        field = name
        break
      end
      field = ''
    end
    if field == '' then
      return value :: adapter.Definition<any>
    end
  end
  local problem: contract.DefinitionError =
    { entryId = id, field = field, code = 'definition', message = 'is not a plugin definition' }
  error(
    table.freeze(setmetatable(
      problem,
      table.freeze {
        __tostring = function(current: contract.DefinitionError): string
          return 'composition: entry '
            .. current.entryId
            .. ': definition field '
            .. current.field
            .. ' '
            .. current.message
        end,
      }
    )),
    0
  )
end

local function prepared(entry: compose.Entry): Prepared
  if entry.id == 'composition' then
    fail 'entry composition is reserved'
  end
  local factory = entry.factory
  -- Validate the source before compose reads its schema, preserving the structured definition error.
  local resolved = compose.resolveEntry {
    id = entry.id,
    definition = if entry.definition then checkedDefinition(entry.id, entry.definition) else nil,
    factory = if factory
      then function(): adapter.Definition<any>
        return checkedDefinition(entry.id, factory())
      end
      else nil,
    config = entry.config,
  }
  return { id = entry.id, definition = resolved.definition, config = preflight(resolved.definition, resolved.config) }
end

function management.start(entries: { compose.Entry }, options: Options?): Running
  local checked = checkedEntries(entries)
  local protectedIds: { [string]: boolean } = { composition = true }
  if options ~= nil then
    if type(options) ~= 'table' then
      fail 'options is a table'
    end
    optionsModule.rejectUnknownFields('composition', (options :: unknown) :: Raw, { protected = true }, 'protected', 0)
    local ids = options.protected
    if ids ~= nil then
      if type(ids) ~= 'table' then
        fail 'protected is a list of entry ids'
      end
      local named: { [string]: boolean } = {}
      for key, id in (ids :: unknown) :: Raw do
        if type(key) ~= 'number' or key < 1 or key > #ids or key ~= math.floor(key) then
          fail('protected has an invalid position ' .. tostring(key))
        end
        if type(id) ~= 'string' or id == '' then
          fail 'protected names a non-empty entry id'
        end
        local protectedId = id :: string
        if named[protectedId] then
          fail('duplicate protected entry ' .. protectedId)
        end
        named[protectedId] = true
        protectedIds[protectedId] = true
      end
    end
  end
  local known: { [string]: boolean } = { composition = true }
  for _, entry in checked do
    known[entry.id] = true
  end
  for id in protectedIds do
    if not known[id] then
      fail('unknown entry ' .. id)
    end
  end
  local initial: { Prepared } = {}
  for _, entry in checked do
    initial[#initial + 1] = prepared(entry)
  end
  local runtime = adapter.runtime()
  local records: { [string]: Record } = {}
  local order: { string } = {}
  local sources: { [string]: Prepared } = {}
  local catalogOrder: { string } = {}
  local changing = true

  local function forget(id: string): ()
    local record = records[id]
    sources[id] = table.freeze { id = id, definition = record.definition, config = record.config }
    records[id] = nil
    local index = table.find(order, id)
    if index then
      table.remove(order, index)
    end
  end

  local function observe(): lunette.PluginRuntimeSnapshot
    local snapshot = runtime:snapshot()
    if changing or snapshot.draining then
      return snapshot
    end
    local states: { [string]: lunette.PluginInstanceSnapshot } = {}
    for _, instance in snapshot.instances do
      states[instance.id] = instance
    end
    for index = #order, 1, -1 do
      local id = order[index]
      local record = records[id]
      local state = record.instance:state()
      local node = states[record.instance:id()]
      if state == 'removed' then
        forget(id)
      elseif state == 'quarantined' then
        record.removing = false
      elseif node and node.retired then
        -- Disposal intent can be accepted even when its implicit drain raises.
        record.removing = true
      elseif state == 'active' then
        record.good = record.config
        record.hasGood = true
        if record.recovering then
          record.previous = nil
          record.hasPrevious = false
          record.recovering = false
        end
      end
    end
    return snapshot
  end

  local function recordFor(id: string): Record
    local record = records[id]
    if not record then
      fail('unknown entry ' .. id)
    end
    return record :: Record
  end

  local function protectedInstances(snapshot: lunette.PluginRuntimeSnapshot): { [string]: boolean }
    local protected: { [string]: boolean } = {}
    for id, record in records do
      if protectedIds[id] then
        protected[record.instance:id()] = true
      end
    end
    local changed = true
    while changed do
      changed = false
      for _, instance in snapshot.instances do
        if protected[instance.id] then
          for _, bindings in { instance.bindings, instance.failedBindings } do
            for _, binding in bindings do
              if not protected[binding.providerId] then
                protected[binding.providerId] = true
                changed = true
              end
            end
          end
          if instance.parentId and not protected[instance.parentId] then
            protected[instance.parentId] = true
            changed = true
          end
        end
      end
    end
    return protected
  end

  local function mutable(id: string): Record
    local record = recordFor(id)
    if protectedIds[id] or protectedInstances(runtime:snapshot())[record.instance:id()] then
      fail('entry ' .. id .. ' is required for management or recovery and cannot be changed')
    end
    if record.removing then
      fail('entry ' .. id .. ' is being removed')
    end
    return record
  end

  local function change(action: () -> ()): ()
    local snapshot = observe()
    if changing or snapshot.draining then
      fail 'entries cannot be changed while the runtime is draining'
    end
    if snapshot.closed or snapshot.closing then
      fail 'the runtime is closed'
    end
    changing = true
    local ok, problem = pcall(action)
    changing = false
    observe()
    if not ok then
      error(problem, 0)
    end
  end

  local function install(source: Prepared): ()
    local instance = runtime:use(source.definition, source.config)
    records[source.id] = {
      definition = source.definition,
      instance = instance,
      config = source.config,
      good = nil,
      hasGood = false,
      previous = nil,
      hasPrevious = false,
      recovering = false,
      removing = false,
    }
    order[#order + 1] = source.id
    if not sources[source.id] then
      catalogOrder[#catalogOrder + 1] = source.id
    end
    sources[source.id] = table.freeze { id = source.id, definition = source.definition, config = source.config }
  end

  local function replace(record: Record, config: unknown, recovering: boolean): ()
    record.instance:requestReload(config)
    if not recovering and record.hasGood then
      record.previous = record.good
      record.hasPrevious = true
    end
    record.config = config
    record.recovering = recovering
    runtime:drain()
  end

  local service: contract.Service = table.freeze {
    catalog = function(_self: contract.Service): { read [number]: contract.KnownEntry }
      observe()
      local result: { contract.KnownEntry } = {}
      for _, id in catalogOrder do
        local definition = sources[id].definition
        result[#result + 1] = table.freeze {
          id = id,
          name = definition.name,
          installed = records[id] ~= nil,
          schema = definition.schema,
          configurable = definition.schema ~= nil and definition.resolve ~= nil,
        }
      end
      return table.freeze(result)
    end,
    entries = function(_self: contract.Service): { contract.Entry }
      local snapshot = observe()
      local states: { [string]: lunette.PluginInstanceSnapshot } = {}
      for _, instance in snapshot.instances do
        states[instance.id] = instance
      end
      local protected = protectedInstances(snapshot)
      local result: { contract.Entry } = {}
      for _, id in order do
        local record = records[id]
        local node = states[record.instance:id()]
        if node then
          result[#result + 1] = table.freeze {
            id = id,
            instanceId = node.id,
            name = record.definition.name,
            config = record.config,
            previousConfig = if record.hasPrevious then record.previous else nil,
            schema = record.definition.schema,
            configurable = record.definition.schema ~= nil and record.definition.resolve ~= nil,
            state = node.state,
            enabled = node.enabled,
            protected = protectedIds[id] == true or protected[node.id] == true,
            diagnostic = node.diagnostic,
          }
        end
      end
      return table.freeze(result)
    end,
    snapshot = function(_self: contract.Service): lunette.PluginRuntimeSnapshot
      return observe()
    end,
    enable = function(_self: contract.Service, id: string): ()
      change(function(): ()
        recordFor(id).instance:enable()
        runtime:drain()
      end)
    end,
    disable = function(_self: contract.Service, id: string): ()
      change(function(): ()
        mutable(id).instance:disable()
        runtime:drain()
      end)
    end,
    reload = function(_self: contract.Service, id: string): ()
      change(function(): ()
        local record = mutable(id)
        replace(record, preflight(record.definition, record.config), false)
      end)
    end,
    configure = function(_self: contract.Service, id: string, config: unknown): ()
      change(function(): ()
        local record = mutable(id)
        if not record.definition.schema or not record.definition.resolve then
          fail('entry ' .. id .. ' has no configuration schema; its source defines its configuration')
        end
        replace(record, preflight(record.definition, config), false)
      end)
    end,
    recover = function(_self: contract.Service, id: string): ()
      change(function(): ()
        local record = mutable(id)
        if not record.hasPrevious then
          fail('entry ' .. id .. ' has no previous configuration')
        end
        replace(record, preflight(record.definition, record.previous), true)
      end)
    end,
    add = function(_self: contract.Service, entry: compose.Entry): ()
      change(function(): ()
        local checkedEntry = checkedEntries({ entry })[1]
        if records[checkedEntry.id] then
          fail('entry ' .. checkedEntry.id .. ' already exists')
        end
        local source = prepared(checkedEntry)
        install(source)
        records[source.id].instance:enable()
        runtime:drain()
      end)
    end,
    restore = function(_self: contract.Service, id: string): ()
      change(function(): ()
        if records[id] then
          fail('entry ' .. id .. ' already exists')
        end
        local source = sources[id]
        if not source then
          fail('unknown entry ' .. id)
        end
        install { id = id, definition = source.definition, config = preflight(source.definition, source.config) }
        records[id].instance:enable()
        runtime:drain()
      end)
    end,
    remove = function(_self: contract.Service, id: string): ()
      change(function(): ()
        local record = mutable(id)
        record.instance:dispose()
        record.removing = true
        runtime:drain()
        if record.instance:state() == 'quarantined' then
          record.removing = false
          fail('entry ' .. id .. ' is quarantined after cleanup; restart the session to release its reservation')
        end
      end)
    end,
    ownerId = function(_self: contract.Service, owner: adapter.Owner): string?
      return runtime:ownerId(owner)
    end,
  }

  local ok, problem = pcall(function(): ()
    local definition = adapter.define {
      name = 'composition',
      provides = { service = contract.capability },
      init = function(_context: adapter.Context, _config: {}, publish: adapter.Publisher): ()
        publish:provide(contract.capability, service)
      end,
    }
    install { id = 'composition', definition = definition, config = table.freeze {} }
    for _, source in initial do
      install(source)
    end
    for _, id in order do
      records[id].instance:enable()
    end
    runtime:drain()
  end)
  changing = false
  if not ok then
    runtime:close()
    error(problem, 0)
  end
  observe()
  return table.freeze { runtime = runtime, service = service }
end

return management
