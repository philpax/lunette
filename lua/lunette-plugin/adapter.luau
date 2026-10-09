-- The adapter maps typed plugin declarations to native runtime handles.

local native = require '@lunette'
local fields = require '@lunette-plugin/fields'
local schema = require '@lunette-plugin/schema'

local adapter = {}

type NativeContext = native.PluginContext
type NativeDefinition = native.PluginDefinition
type NativeEffect = native.PluginEffect
type NativeInstance = native.PluginInstance

-- The witness carries the service type selected when the capability is declared.
export type Capability<T> = {
  read witness: (T) -> T,
}

export type CapabilitySpec = {
  read name: string,
  read version: number,
}

export type Effect = {
  read dispose: (Effect) -> (),
}

-- An owner releases each acquired effect when its activation ends. The type is a brand that every context satisfies
-- and that exposes nothing callable, so a provider registers on an owner only through `Context:acquire`.
export type Owner = {
  read active: (never) -> boolean,
}

export type Subscription<E> = {
  read event: ((E) -> ()) -> () -> (),
  read run: (E) -> (),
}

export type Context = {
  read require: <T>(Context, Capability<T>) -> T,
  read effect: (Context, () -> () -> ()) -> Effect,
  read child: <C>(Context, Definition<C>, C?) -> (),
  read checkOwner: (Context, Owner) -> (),
  read owns: (Context, Owner) -> boolean,
  read acquire: (Context, Owner, () -> () -> ()) -> Effect,
  read acquireDeferred: (Context, Owner, () -> () -> ()) -> Effect,
  read resource: <T>(Context, Owner, () -> (T, () -> ())) -> (T, Effect),
  read on: <E>(Context, Subscription<E>) -> Effect,
  read active: (Context) -> boolean,
}

export type Publisher = {
  read provide: <T>(Publisher, Capability<T>, T) -> (),
}

-- A list of capabilities. The facade keys each by its contract for the native graph.
export type Declaration = { { read witness: (never) -> unknown } }

export type Spec<C> = {
  read name: string,
  read requires: Declaration?,
  read provides: Declaration?,
  read init: (Context, C, Publisher) -> (),
}

-- The context and publisher use `never` because a recursive `Context` type stops `Context:child` from checking its
-- configuration against `C`.
export type Definition<C> = {
  read name: string,
  read requires: Declaration,
  read provides: Declaration,
  read init: (never, C, never) -> (),
  read schema: schema.Metadata?,
  read resolve: ((unknown) -> unknown)?,
}

export type Configuration = {
  read schema: schema.Metadata?,
  read resolve: (unknown) -> unknown,
}

type DefinitionRecord<C> = Definition<C> & {
  read nativeDefinition: NativeDefinition,
}

export type Instance<C> = {
  read id: (Instance<C>) -> string,
  read enable: (Instance<C>) -> (),
  read disable: (Instance<C>) -> (),
  read dispose: (Instance<C>) -> (),
  read requestReload: (Instance<C>, C) -> (),
  read state: (Instance<C>) -> native.PluginState,
}

export type Runtime = {
  read use: <C>(Runtime, Definition<C>, C) -> Instance<C>,
  read snapshot: (Runtime) -> native.PluginRuntimeSnapshot,
  read ownerId: (Runtime, Owner) -> string?,
  read close: (Runtime) -> (),
  read drain: (Runtime) -> (),
}

type ErasedDeclaration = { [string]: unknown }
type StagedValues = { [string]: unknown }
type Staging = {
  open: boolean,
  active: () -> boolean,
  values: StagedValues,
  called: { [string]: boolean },
}

local function freeze<T>(value: T): T
  return table.freeze(value)
end

local EMPTY = freeze {}

local function contractName(capability: unknown): string?
  if type(capability) == 'table' then
    local contract = rawget(capability :: { [string]: unknown }, 'contract')
    if type(contract) == 'string' then
      return contract
    end
  end
  return nil
end

-- Copies a declaration after checking that it is a dense list of distinct capabilities.
local function declarationSnapshot(field: string, value: unknown, level: number): Declaration
  if value == nil then
    return freeze {}
  end
  if type(value) ~= 'table' then
    error('plugin define: ' .. field .. ' is a list of capabilities, not a ' .. type(value), level)
  end
  local raw = value :: { [unknown]: unknown }
  local count = rawlen(raw :: any)
  local seen: { [string]: boolean } = {}
  for key, capability in raw do
    if type(key) ~= 'number' or key < 1 or key > count or key % 1 ~= 0 then
      error(
        'plugin define: ' .. field .. ' is a list of capabilities, and ' .. tostring(key) .. ' is not a position',
        level
      )
    end
    local contract = contractName(capability)
    if contract == nil then
      error('plugin define: ' .. field .. ' lists a ' .. type(capability) .. ', not a capability', level)
    end
    if seen[contract :: string] then
      error('plugin define: ' .. field .. ' lists capability ' .. (contract :: string) .. ' twice', level)
    end
    seen[contract :: string] = true
  end
  return freeze(table.clone(raw :: any)) :: Declaration
end

local function declarationTokens(declaration: Declaration): ErasedDeclaration
  local tokens: ErasedDeclaration = {}
  for _, capability in declaration do
    tokens[contractName(capability) :: string] = rawget(capability :: any, 'token')
  end
  return tokens
end

local function describeCapability(capability: unknown): string
  local contract = contractName(capability)
  return if contract then 'capability ' .. contract else 'a value that is not a capability'
end

-- Answers the contract that keys a declared capability in the native graph.
local function memberField(operation: string, declaration: Declaration, capability: unknown): string
  for _, declared in declaration do
    if rawequal(declared, capability) then
      return contractName(capability) :: string
    end
  end
  error(string.format('plugin %s: %s is not declared', operation, describeCapability(capability)), 3)
end

local function unwrapDefinition<C>(definition: Definition<C>): NativeDefinition
  return ((definition :: unknown) :: DefinitionRecord<C>).nativeDefinition
end

-- Wrapper identity prevents caller-created tables from acting as owners.
-- The native context validates that the owner is a live dependent.
local nativeContexts: { [Context]: NativeContext } = setmetatable({}, { __mode = 'k' }) :: any
local ownerLabels: { [Owner]: string } = setmetatable({}, { __mode = 'k' })

-- Reads registered metadata without invoking the owner's callbacks.
function adapter.ownerLabel(owner: Owner): string
  return ownerLabels[owner] or 'unregistered owner'
end

local function ownerContext(owner: Owner, level: number): NativeContext
  local nativeContext = nativeContexts[(owner :: unknown) :: Context]
  if nativeContext == nil then
    error('plugin checkOwner: the owner is not a plugin context', level)
  end
  return nativeContext
end

local rejectUnknownFields = fields.rejectUnknownFields

-- An owner is the provider's own context or a live dependent of it, for every owner-scoped acquisition alike.
local function ownedBy(nativeContext: NativeContext, owner: Owner): NativeContext
  local callerContext = ownerContext(owner, 4)
  if callerContext ~= nativeContext then
    nativeContext:checkOwner(callerContext)
  end
  return callerContext
end

local function wrapContext(nativeContext: NativeContext, required: Declaration): Context
  local wrapped = {
    require = function<T>(_self: Context, capability: Capability<T>): T
      local field = memberField('require', required, capability)
      local services = (nativeContext:services() :: unknown) :: ErasedDeclaration
      return (services[field] :: unknown) :: T
    end,
    effect = function(_self: Context, acquire: () -> () -> ()): Effect
      local effect: NativeEffect = nativeContext:effect(acquire)
      return (effect :: unknown) :: Effect
    end,
    child = function<C>(_self: Context, definition: Definition<C>, config: C?): ()
      local instance: NativeInstance =
        nativeContext:child(unwrapDefinition(definition), if config == nil then EMPTY else config)
      instance:enable()
    end,
    checkOwner = function(_self: Context, caller: Owner): ()
      nativeContext:checkOwner(ownerContext(caller, 3))
    end,
    owns = function(_self: Context, caller: Owner): boolean
      local callerContext = nativeContexts[(caller :: unknown) :: Context]
      return callerContext ~= nil and nativeContext:owns(callerContext)
    end,
    acquire = function(_self: Context, owner: Owner, acquire: () -> () -> ()): Effect
      local effect: NativeEffect = ownedBy(nativeContext, owner):effect(acquire)
      return (effect :: unknown) :: Effect
    end,
    acquireDeferred = function(_self: Context, owner: Owner, acquire: () -> () -> ()): Effect
      local effect: NativeEffect = ownedBy(nativeContext, owner):effectDeferred(acquire)
      return (effect :: unknown) :: Effect
    end,
    resource = function<T>(_self: Context, owner: Owner, acquire: () -> (T, () -> ())): (T, Effect)
      local value: T
      local effect: NativeEffect = ownedBy(nativeContext, owner):effect(function(): () -> ()
        local acquired, inverse = acquire()
        value = acquired
        return inverse
      end)
      return value, (effect :: unknown) :: Effect
    end,
    on = function<E>(_self: Context, subscription: Subscription<E>): Effect
      if type(subscription) ~= 'table' then
        error('plugin on: a subscription is a table of fields, not a ' .. type(subscription), 2)
      end
      rejectUnknownFields('plugin on', subscription, { 'event', 'run' }, 2)
      local subscribe, handler = subscription.event, subscription.run
      if type(subscribe) ~= 'function' then
        error('plugin on: event is a subscribing function, not a ' .. type(subscribe), 2)
      end
      if type(handler) ~= 'function' then
        error('plugin on: run is a function, not a ' .. type(handler), 2)
      end
      local effect: NativeEffect = nativeContext:effect(function(): () -> ()
        -- Events delivered after activation ends are dropped until the inverse
        -- cancels the subscription, including errors reported during resource release.
        local cancel: unknown = subscribe(function(event: E): ()
          if nativeContext:active() then
            handler(event)
          end
        end)
        if type(cancel) ~= 'function' then
          error('plugin on: a subscription answers the function that cancels it, not a ' .. type(cancel), 0)
        end
        return cancel :: () -> ()
      end)
      return (effect :: unknown) :: Effect
    end,
    active = function(_self: Context): boolean
      return nativeContext:active()
    end,
  }
  local context = (freeze(wrapped) :: unknown) :: Context
  nativeContexts[context] = nativeContext
  return context
end

local function validateCapabilitySpec(spec: CapabilitySpec): CapabilitySpec
  local level = 4
  if type(spec) ~= 'table' then
    error('plugin capability: a capability is a table of fields, not a ' .. type(spec), level)
  end
  local raw = (spec :: unknown) :: { [unknown]: unknown }
  rejectUnknownFields('plugin capability', raw, { 'name', 'version' }, level)
  local name = raw.name
  if type(name) ~= 'string' then
    error('plugin capability: name is a string, not a ' .. type(name), level)
  end
  if name == '' then
    error('plugin capability: name is empty', level)
  end
  local version = raw.version
  if type(version) ~= 'number' then
    error('plugin capability: version is a number, not a ' .. type(version), level)
  end
  if version ~= math.floor(version) or version < 1 or version == math.huge then
    error('plugin capability: version is a positive integer, not ' .. tostring(version), level)
  end
  return { name = name, version = version }
end

function adapter.capability<T>(spec: CapabilitySpec): Capability<T>
  local checked = validateCapabilitySpec(spec)
  return freeze {
    token = native.plugin.contract(checked.name, checked.version),
    witness = function(value: T): T
      return value
    end,
    contract = checked.name .. '@' .. tostring(checked.version),
  }
end

local function revoked(contract: string): string
  return 'plugin service: ' .. contract .. ' is no longer available because its provider activation has ended'
end

-- Reads raise after the provider activation ends, while a method read earlier stays callable. Guarding the read keeps
-- the provider error's call site. Writes always raise.
local function guardService(value: unknown, contract: string, provider: NativeContext): unknown
  if type(value) == 'function' then
    local call = value :: (...unknown) -> ...unknown
    return function(...: unknown): ...unknown
      if not provider:serving() then
        error(revoked(contract), 2)
      end
      return call(...)
    end
  end
  if type(value) ~= 'table' then
    return value
  end
  local raw = value :: { [unknown]: unknown }
  local view = {
    __index = function(_proxy: unknown, key: unknown): unknown
      if not provider:serving() then
        error(revoked(contract), 2)
      end
      return raw[key]
    end,
    __newindex = function(_proxy: unknown, key: unknown, _value: unknown): ()
      error('plugin service: ' .. contract .. ' is read-only, so ' .. tostring(key) .. ' cannot be assigned', 2)
    end,
    __iter = function(_proxy: unknown): ((unknown, unknown) -> (unknown, unknown), unknown)
      if not provider:serving() then
        error(revoked(contract), 2)
      end
      return next :: any, raw
    end,
    __call = nil :: ((unknown, ...unknown) -> ...unknown)?,
  }
  local rawMetatable: unknown = getmetatable(raw :: any)
  if type(rawMetatable) == 'table' then
    local rawCall = rawget(rawMetatable :: { [string]: unknown }, '__call')
    if type(rawCall) == 'function' then
      local call = rawCall :: (unknown, ...unknown) -> ...unknown
      view.__call = function(proxy: unknown, ...: unknown): ...unknown
        if not provider:serving() then
          error(revoked(contract), 2)
        end
        return call(proxy, ...)
      end
    end
  end
  return freeze(setmetatable({}, freeze(view) :: any))
end

-- Native validation rejects a record that omits a declared provision.
local function stagedValues(values: StagedValues, provider: NativeContext): StagedValues
  local result: StagedValues = {}
  for contract, value in values do
    result[contract] = guardService(value, 'capability ' .. contract, provider)
  end
  return result
end

local function publisher(provided: Declaration, staging: Staging): Publisher
  return freeze {
    provide = function<T>(_self: Publisher, capability: Capability<T>, value: T): ()
      if not staging.open or not staging.active() then
        error('plugin provision: initializer is no longer active', 2)
      end
      local field = memberField('provision', provided, capability)
      if staging.called[field] then
        error('plugin provision: duplicate provision ' .. field, 2)
      end
      if value == nil then
        error('plugin provision: provision ' .. field .. ' was nil', 2)
      end
      staging.called[field] = true
      staging.values[field] = value
    end,
  }
end

type ValidSpec<C> = {
  name: string,
  requires: Declaration,
  provides: Declaration,
  init: (Context, C, Publisher) -> (),
}

local function validateSpec<C>(spec: Spec<C>): ValidSpec<C>
  local level = 3
  if type(spec) ~= 'table' then
    error('plugin define: a definition is a table of fields, not a ' .. type(spec), level)
  end
  local raw = (spec :: unknown) :: { [unknown]: unknown }
  rejectUnknownFields('plugin define', raw, { 'name', 'requires', 'provides', 'init' }, level)
  local name = raw.name
  if type(name) ~= 'string' then
    error('plugin define: name is a string, not a ' .. type(name), level)
  end
  if name == '' then
    error('plugin define: name is empty', level)
  end
  local init = raw.init
  if type(init) ~= 'function' then
    error('plugin define: init is a function, not a ' .. type(init), level)
  end
  return {
    name = name,
    requires = declarationSnapshot('requires', raw.requires, level + 1),
    provides = declarationSnapshot('provides', raw.provides, level + 1),
    init = spec.init,
  }
end

-- Records every definition `define` made, so a forged table is not accepted as one.
local definitions: { [unknown]: boolean } = setmetatable({}, { __mode = 'k' }) :: any

function adapter.isDefinition(value: unknown): boolean
  return definitions[value] == true
end

function adapter.define<C>(spec: Spec<C>, configuration: Configuration?): Definition<C>
  local checked = validateSpec(spec)
  local init = checked.init
  local requiredSnapshot = checked.requires
  local providedSnapshot = checked.provides
  local nativeDefinition = native.plugin.define(
    declarationTokens(requiredSnapshot),
    declarationTokens(providedSnapshot),
    function(nativeContext: NativeContext, config: unknown): unknown
      local staging: Staging = {
        open = true,
        active = function(): boolean
          return nativeContext:active()
        end,
        values = {},
        called = {},
      }
      -- Rollback clears staged services even when the publisher escaped the initializer.
      nativeContext:effect(function(): () -> ()
        return function(): ()
          staging.open = false
          staging.values = {}
          staging.called = {}
        end
      end)
      local context = wrapContext(nativeContext, requiredSnapshot)
      ownerLabels[context] = checked.name
      local typedConfig = (config :: unknown) :: C
      local provide = publisher(providedSnapshot, staging)
      local returned = select('#', init(context, typedConfig, provide))
      staging.open = false
      local values = staging.values
      staging.values = {}
      staging.called = {}
      if returned ~= 0 then
        error('plugin provision: initializer must return nothing', 0)
      end
      return stagedValues(values, nativeContext)
    end,
    checked.name
  )
  local definition = freeze {
    name = checked.name,
    requires = requiredSnapshot,
    provides = providedSnapshot,
    init = init,
    schema = if configuration then configuration.schema else nil,
    resolve = if configuration then configuration.resolve else nil,
    nativeDefinition = nativeDefinition,
  } :: Definition<C>
  definitions[definition] = true
  return definition
end

function adapter.runtime(): Runtime
  local nativeRuntime = native.plugin.runtime()
  local runtime = {
    use = function<C>(_self: Runtime, definition: Definition<C>, config: C): Instance<C>
      local instance: NativeInstance = nativeRuntime:use(unwrapDefinition(definition), config)
      return (instance :: unknown) :: Instance<C>
    end,
    snapshot = function(_self: Runtime): native.PluginRuntimeSnapshot
      return nativeRuntime:snapshot()
    end,
    ownerId = function(_self: Runtime, owner: Owner): string?
      local context = nativeContexts[(owner :: unknown) :: Context]
      return if context then nativeRuntime:ownerId(context) else nil
    end,
    close = function(_self: Runtime): ()
      nativeRuntime:close()
    end,
    drain = function(_self: Runtime): ()
      nativeRuntime:drain()
    end,
  }
  return (freeze(runtime) :: unknown) :: Runtime
end

return adapter
