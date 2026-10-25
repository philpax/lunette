-- Owns session entries, previous-good configuration, the last composition marked good, and saved settings over one
-- nontransactional plugin runtime.

local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local contract = require '@lunette-contracts/composition'
local lunette = require '@lunette'
local fields = require '@lunette-plugin/fields'
local management = {}

export type Entry = contract.Entry
-- Protected entries refuse every change, and so do the providers they depend on, except the providers named in
-- `reconfigurable`, which can be reloaded and reconfigured but still not disabled or removed. A provider belongs in
-- `reconfigurable` only when a broken configuration of it is recoverable in VR, as the UI toolkit's are through
-- default appearance and the recovery plugin.
--
-- `saved` keeps saved settings: an override of configuration fields for each entry id. The runtime applies each
-- entry's valid fields over its configuration at start, records the fields that differ from that configuration when
-- the entry is configured or saves its own changes, changes `overrides` in place, and then calls `write`.
export type Options = { read protected: { string }?, read reconfigurable: { string }?, read saved: Saved? }
export type Saved = {
  read overrides: { [string]: { [string]: unknown } },
  read write: () -> (),
  -- Reports a saved setting that does not apply or cannot be saved.
  read report: (string) -> (),
  -- Whether the file can hold a value.
  read storable: (unknown) -> boolean,
}
export type Running = {
  read runtime: adapter.Runtime,
  read service: contract.Service,
}

type Prepared = { read id: string, read definition: adapter.Definition<any>, read config: unknown }
type Record = {
  definition: adapter.Definition<any>,
  instance: adapter.Instance<any>,
  config: unknown,
  -- The configuration before saved settings, which saved fields are measured against.
  base: unknown,
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

-- The entry with fields merged over its configuration by the entry's schema, ready to start.
local function merged(entry: compose.Entry, fields: { [string]: unknown }): Prepared
  return prepared(compose.apply({ entry }, { { id = entry.id, config = fields } })[1])
end

-- The configuration as the entry's schema resolves it, with defaults for the fields it leaves out, or nil for an entry
-- without a schema or a configuration the schema refuses.
local function resolvedFields(
  definition: adapter.Definition<any>,
  config: { [string]: unknown }
): { [string]: unknown }?
  local resolve = definition.resolve
  if not resolve then
    return nil
  end
  local ok, result = pcall(resolve, config)
  return if ok and type(result) == 'table' then result :: { [string]: unknown } else nil
end

-- Structural equality over configuration values: tables compare by their keys and values, everything else by `==`.
local function equal(left: unknown, right: unknown): boolean
  if left == right then
    return true
  end
  if type(left) ~= 'table' or type(right) ~= 'table' then
    return false
  end
  local a, b = left :: { [unknown]: unknown }, right :: { [unknown]: unknown }
  for key, value in a do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in b do
    if a[key] == nil then
      return false
    end
  end
  return true
end

function management.start(entries: { compose.Entry }, options: Options?): Running
  local checked = compose.apply(entries)
  local saved = options and options.saved
  local protectedIds: { [string]: boolean } = { composition = true }
  local reconfigurableIds: { [string]: boolean } = {}
  local function list(name: string, ids: unknown, into: { [string]: boolean }): ()
    if ids ~= nil and type(ids) ~= 'table' then
      fail(name .. ' is a list of entry ids')
    end
    for _, id in (ids or {}) :: { unknown } do
      if type(id) ~= 'string' then
        fail(name .. ' names an entry id, not a ' .. type(id))
      end
      into[id :: string] = true
    end
  end
  if options ~= nil then
    fields.rejectUnknownFields('composition', options, { 'protected', 'reconfigurable', 'saved' }, 0)
    list('protected', options.protected, protectedIds)
    list('reconfigurable', options.reconfigurable, reconfigurableIds)
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
  -- Saved fields that fail their entry's schema, by entry id, with the reason; they stay in the file unapplied.
  local invalid: { [string]: { [string]: string } } = {}
  -- Entries that failed to start with their saved fields, which start with their base configuration instead.
  local suspended: { [string]: boolean } = {}
  local bases: { [string]: unknown } = {}
  -- Applies an entry's saved fields one at a time, so one invalid field leaves the others applied.
  local function withSaved(entry: compose.Entry, base: Prepared): Prepared
    local store = saved
    local override = store and store.overrides[entry.id]
    if not store or not override or not base.definition.schema then
      return base
    end
    local valid: { [string]: unknown } = {}
    local applied = false
    for field, value in override do
      local single: { [string]: unknown } = {}
      single[field] = value
      local ok, problem = pcall(merged, entry, single)
      if ok then
        valid[field] = value
        applied = true
      else
        invalid[entry.id] = invalid[entry.id] or {}
        invalid[entry.id][field] = tostring(problem)
        store.report(`the saved {entry.id} setting {field} does not apply: {tostring(problem)}`)
      end
    end
    if not applied then
      return base
    end
    local ok, result = pcall(merged, entry, valid)
    if not ok then
      suspended[entry.id] = true
      store.report(`the saved {entry.id} settings do not apply together, so none apply: {tostring(result)}`)
      return base
    end
    return result
  end
  local initial: { Prepared } = {}
  for _, entry in checked do
    local base = prepared(entry)
    bases[entry.id] = base.config
    initial[#initial + 1] = withSaved(entry, base)
  end
  local saveChanges: adapter.Saver
  local runtime = adapter.runtime(if saved
    then {
      save = function(instanceId: string, changes: { [string]: unknown }): ()
        saveChanges(instanceId, changes)
      end,
    }
    else nil)
  local records: { [string]: Record } = {}
  local order: { string } = {}
  local sources: { [string]: Prepared } = {}
  local catalogOrder: { string } = {}
  local changing = true
  local good: contract.GoodConfiguration? = nil
  local observed: { contract.GoodEntry } = table.freeze({} :: { contract.GoodEntry })
  local revision = 0

  local function forget(id: string): ()
    local record = records[id]
    sources[id] = table.freeze { id = id, definition = record.definition, config = record.config }
    records[id] = nil
    local index = table.find(order, id)
    if index then
      table.remove(order, index)
    end
  end

  local function reconcile(status: lunette.PluginRuntimeStatus): ()
    if changing or status.draining then
      return
    end
    for index = #order, 1, -1 do
      local id = order[index]
      local record = records[id]
      local state = record.instance:state()
      local _, retired = record.instance:intent()
      if state == 'removed' then
        forget(id)
      elseif state == 'quarantined' then
        record.removing = false
      elseif retired then
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
  end

  local function observe(): lunette.PluginRuntimeSnapshot
    local snapshot = runtime:snapshot()
    reconcile(snapshot)
    return snapshot
  end

  local function recordFor(id: string): Record
    local record = records[id]
    if not record then
      fail('unknown entry ' .. id)
    end
    return record :: Record
  end

  local function savedFor(id: string): { [string]: unknown }?
    local store = saved
    return if store then store.overrides[id] else nil
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

  -- A protected entry refuses every change. A provider that a protected entry depends on is required: it cannot be
  -- disabled or removed, and it can be reloaded and reconfigured only when it is named reconfigurable.
  local function mutable(id: string, structural: boolean): Record
    local record = recordFor(id)
    if protectedIds[id] then
      fail('entry ' .. id .. ' is protected for management or recovery and cannot be changed')
    end
    if protectedInstances(runtime:snapshot())[record.instance:id()] then
      if structural then
        fail('entry ' .. id .. ' is required by a protected entry and cannot be disabled or removed')
      elseif not reconfigurableIds[id] then
        fail('entry ' .. id .. ' is required by a protected entry and cannot be changed')
      end
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
      base = if bases[source.id] ~= nil then bases[source.id] else source.config,
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

  -- Records the fields of an entry's configuration that differ from its base as the entry's saved settings, keeping
  -- saved fields that do not apply. A value the file cannot hold is reported and left out.
  local function recordSaved(id: string, entry: Record): ()
    if not saved then
      return
    end
    local override: { [string]: unknown } = {}
    local config = (if type(entry.config) == 'table' then entry.config else {}) :: { [string]: unknown }
    local base = (if type(entry.base) == 'table' then entry.base else {}) :: { [string]: unknown }
    -- A field the base leaves out takes its schema default, so a value equal to that default is not a difference.
    local defaults = resolvedFields(entry.definition, base)
    for field, value in config do
      local unchanged = equal(value, base[field])
        or (base[field] == nil and defaults ~= nil and equal(value, defaults[field]))
      if not unchanged then
        if saved.storable(value) then
          override[field] = value
        else
          saved.report(`the {id} setting {field} cannot be saved, because the file cannot hold its value`)
        end
      end
    end
    local kept = saved.overrides[id]
    for field in invalid[id] or {} do
      if kept and kept[field] ~= nil and override[field] == nil then
        override[field] = kept[field]
      end
    end
    saved.overrides[id] = if next(override) then override else nil
    suspended[id] = nil
    saved.write()
  end

  -- An entry's own changes merge into its configuration without a reload, and are recorded like a configure.
  saveChanges = function(instanceId: string, changes: { [string]: unknown }): ()
    for id, entry in records do
      if entry.instance:id() == instanceId then
        local result = merged({ id = id, definition = entry.definition, config = entry.config :: any }, changes)
        entry.config = result.config
        recordSaved(id, entry)
        return
      end
    end
    fail "only an entry's own context saves its settings"
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

  local function observation(toolkit: { read [number]: string }): contract.Observation
    local status = runtime:status()
    reconcile(status)
    local changed = false
    local count = 0
    for _, id in order do
      local record = records[id]
      if record.instance:state() ~= 'removed' then
        count += 1
        local enabled = record.instance:intent()
        local previous = observed[count]
        if
          not previous
          or previous.id ~= id
          or previous.enabled ~= enabled
          or not equal(previous.config, record.config)
        then
          changed = true
        end
      end
    end
    if changed or count ~= #observed then
      revision += 1
      local captured: { contract.GoodEntry } = {}
      for _, id in order do
        local record = records[id]
        if record.instance:state() ~= 'removed' then
          captured[#captured + 1] = table.freeze {
            id = id,
            config = record.config,
            enabled = record.instance:intent(),
          }
        end
      end
      observed = table.freeze(captured)
    end
    local missing: { string } = {}
    for _, name in toolkit do
      if not runtime:hasActiveProvider(name) then
        missing[#missing + 1] = name
      end
    end
    return table.freeze {
      revision = revision,
      entries = observed,
      missing = table.freeze(missing),
      draining = status.draining,
      closing = status.closing,
      closed = status.closed,
    }
  end

  local service: contract.Service = table.freeze {
    observe = function(_self: contract.Service, toolkit: { read [number]: string }): contract.Observation
      return observation(toolkit)
    end,
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
            protected = protectedIds[id] == true or (protected[node.id] == true and not reconfigurableIds[id]),
            baseConfig = record.base,
            saved = savedFor(id),
            required = protectedIds[id] == true or protected[node.id] == true,
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
        mutable(id, true).instance:disable()
        runtime:drain()
      end)
    end,
    reload = function(_self: contract.Service, id: string): ()
      change(function(): ()
        local record = mutable(id, false)
        replace(record, preflight(record.definition, record.config), false)
      end)
    end,
    configure = function(_self: contract.Service, id: string, config: unknown): ()
      change(function(): ()
        local record = mutable(id, false)
        if not record.definition.schema or not record.definition.resolve then
          fail('entry ' .. id .. ' has no configuration schema; its source defines its configuration')
        end
        replace(record, preflight(record.definition, config), false)
        recordSaved(id, record)
      end)
    end,
    recover = function(_self: contract.Service, id: string): ()
      change(function(): ()
        local record = mutable(id, false)
        if not record.hasPrevious then
          fail('entry ' .. id .. ' has no previous configuration')
        end
        replace(record, preflight(record.definition, record.previous), true)
        recordSaved(id, record)
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
        local record = mutable(id, true)
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
    markGood = function(_self: contract.Service): ()
      local snapshot = observe()
      if changing or snapshot.draining then
        fail 'a composition cannot be marked good while the runtime is draining'
      end
      if snapshot.closed or snapshot.closing then
        fail 'the runtime is closed'
      end
      local enabled: { [string]: boolean } = {}
      for _, instance in snapshot.instances do
        enabled[instance.id] = instance.enabled
      end
      local recorded: { contract.GoodEntry } = {}
      for _, id in order do
        local record = records[id]
        if id ~= 'composition' and not record.removing then
          recorded[#recorded + 1] = table.freeze {
            id = id,
            config = record.config,
            enabled = enabled[record.instance:id()] == true,
          }
        end
      end
      good = table.freeze { entries = table.freeze(recorded) }
    end,
    lastGood = function(_self: contract.Service): contract.GoodConfiguration?
      return good
    end,
    savedSettings = function(_self: contract.Service): { read [number]: contract.SavedSetting }
      local result: { contract.SavedSetting } = {}
      if not saved then
        return table.freeze(result)
      end
      local ids: { string } = {}
      for id in saved.overrides do
        ids[#ids + 1] = id
      end
      table.sort(ids)
      for _, id in ids do
        local fieldNames: { string } = {}
        for field in saved.overrides[id] do
          fieldNames[#fieldNames + 1] = field
        end
        table.sort(fieldNames)
        for _, field in fieldNames do
          local problem = invalid[id] and invalid[id][field]
          local status: contract.SavedStatus = if records[id] == nil
            then 'unused'
            elseif problem then 'invalid'
            elseif suspended[id] then 'suspended'
            else 'applied'
          result[#result + 1] = table.freeze {
            id = id,
            field = field,
            value = saved.overrides[id][field],
            status = status,
            problem = problem,
          }
        end
      end
      return table.freeze(result)
    end,
    suspendSaved = function(_self: contract.Service): number
      local returned = 0
      for _, id in table.clone(order) do
        local entry = records[id]
        if entry and entry.config ~= entry.base and savedFor(id) and entry.definition.schema then
          local ok = pcall(change, function(): ()
            replace(mutable(id, false), entry.base, false)
          end)
          if ok then
            suspended[id] = true
            returned += 1
          end
        end
      end
      return returned
    end,
    forgetSaved = function(_self: contract.Service, id: string, field: string?): ()
      if not saved or not saved.overrides[id] then
        return
      end
      local override = saved.overrides[id]
      if field then
        override[field] = nil
        if invalid[id] then
          invalid[id][field] = nil
        end
      else
        table.clear(override)
        invalid[id] = nil
      end
      if not next(override) then
        saved.overrides[id] = nil
      end
      suspended[id] = nil
      saved.write()
      local entry = records[id]
      -- A composed entry returns to its base configuration with the saved fields that remain; a protected one keeps
      -- running as it is, and the change applies at the next start.
      if entry and entry.definition.schema and not protectedIds[id] then
        change(function(): ()
          local remaining: { [string]: unknown } = {}
          for name, value in savedFor(id) or {} do
            if not (invalid[id] and invalid[id][name]) then
              remaining[name] = value
            end
          end
          local target = merged({ id = id, definition = entry.definition, config = entry.base :: any }, remaining)
          replace(mutable(id, false), target.config, false)
        end)
      end
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
    -- An entry that fails to start with saved fields starts again from its base configuration, so a saved setting
    -- cannot break the entry at every start.
    local retried = false
    for _, id in order do
      local entry = records[id]
      if entry.config ~= entry.base and entry.instance:state() == 'failed' then
        suspended[id] = true
        local store = saved
        if store then
          store.report(`{id} failed to start with its saved settings, so it starts without them until they are reset`)
        end
        entry.config = entry.base
        entry.instance:requestReload(entry.base)
        retried = true
      end
    end
    if retried then
      runtime:drain()
    end
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
