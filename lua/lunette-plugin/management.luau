-- Owns session entries and previous-good configuration over one nontransactional plugin runtime.

local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local contract = require '@lunette-contracts/composition'
local lunette = require '@lunette'
local fields = require '@lunette-plugin/fields'
local management = {}

export type Options = { read protected: { string }? }
export type Running = {
  read runtime: adapter.Runtime,
  read service: contract.Service,
}

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

local function preflight(definition: adapter.Definition<any>, config: unknown): unknown
  local snapshot = compose.snapshot(config, definition.schema)
  local resolve = definition.resolve
  if resolve then
    resolve(snapshot)
  end
  return snapshot
end

local function prepared(entry: compose.Entry): Prepared
  if entry.id == 'composition' then
    fail 'entry composition is reserved'
  end
  local resolved = compose.resolveEntry(entry)
  return { id = entry.id, definition = resolved.definition, config = preflight(resolved.definition, resolved.config) }
end

function management.start(entries: { compose.Entry }, options: Options?): Running
  local checked = compose.apply(entries)
  local protectedIds: { [string]: boolean } = { composition = true }
  if options ~= nil then
    fields.rejectUnknownFields('composition', options, { 'protected' }, 0)
    local ids: unknown = options.protected
    if ids ~= nil and type(ids) ~= 'table' then
      fail 'protected is a list of entry ids'
    end
    for _, id in (ids or {}) :: { unknown } do
      if type(id) ~= 'string' then
        fail('protected names an entry id, not a ' .. type(id))
      end
      protectedIds[id :: string] = true
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
      provides = { contract.capability },
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
