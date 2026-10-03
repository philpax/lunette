-- The erased boundary for plugin declarations and native runtime handles. Declarations keep the frozen
-- capability wrappers registered at binding, and published services reach consumers as frozen proxies that
-- the provider's activation guards.

local native = require '@lunette'
local options = require '@lunette-plugin/options'

local adapter = {}

type NativeContext = native.PluginContext
type NativeDefinition = native.PluginDefinition
type NativeEffect = native.PluginEffect
type NativeInstance = native.PluginInstance

-- A contract's capability. The service type `T` is named at the call site by
-- explicit instantiation, as in `plugin.capability<<Service>> { ... }`, and
-- the witness is an identity function that carries it.
export type Capability<T> = {
  read witness: (T) -> T,
}

-- The fields `plugin.capability` accepts.
export type CapabilitySpec = {
  read name: string,
  read schema: number,
}

export type Effect = {
  read dispose: (Effect) -> (),
}

-- A caller lifetime that a provider acquires resources for, so the resource is released when the caller's
-- activation ends.
export type Owner = {
  read services: (never) -> unknown,
  read effect: (Owner, () -> () -> ()) -> Effect,
}

-- What `Context:on` takes. `event` is a subscribing function that takes a
-- handler and answers the function that cancels it, the shape of every
-- `lunette.on*` event, and `run` is the handler.
export type Subscription<E> = {
  read event: ((E) -> ()) -> () -> (),
  read run: (E) -> (),
}

export type Context = {
  read services: (never) -> unknown,
  read require: <T>(Context, Capability<T>) -> T,
  read effect: (Owner, () -> () -> ()) -> Effect,
  read child: <C>(Context, Definition<C>, C) -> Instance<C>,
  read checkOwner: (Context, Owner) -> (),
  read owns: (Context, Owner) -> boolean,
  read acquire: (Context, Owner, () -> () -> ()) -> Effect,
  read on: <E>(Context, Subscription<E>) -> Effect,
  read active: (Context) -> boolean,
}

export type Publisher = {
  read provide: <T>(Publisher, Capability<T>, T) -> (),
}

export type Declaration = { [string]: { read witness: (never) -> unknown } }

-- The fields `plugin.define` accepts. The configuration type `C` is inferred
-- from the initializer's configuration parameter.
export type Spec<C> = {
  read name: string,
  read requires: Declaration?,
  read provides: Declaration?,
  read init: (Context, C, Publisher) -> (),
}

-- A defined plugin. The initializer's context and publisher are erased to
-- `never`: naming `Context` here makes `Definition` and `Context` mutually
-- recursive, and `Context:child` then no longer checks its configuration
-- argument against `C`.
export type Definition<C> = {
  read name: string,
  read requires: Declaration,
  read provides: Declaration,
  read init: (never, C, never) -> (),
}

type DefinitionRecord<C> = Definition<C> & {
  read nativeDefinition: NativeDefinition,
}

export type Instance<C> = {
  read enable: (Instance<C>) -> (),
  read disable: (Instance<C>) -> (),
  read dispose: (Instance<C>) -> (),
  read reload: (Instance<C>, C) -> (),
  read state: (Instance<C>) -> native.PluginState,
  read diagnostic: (Instance<C>) -> string?,
}

export type Runtime = {
  read use: <C>(Runtime, Definition<C>, C) -> Instance<C>,
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

local function declarationSnapshot(value: Declaration): Declaration
  return freeze(table.clone(value))
end

-- Names a capability for an error message by its contract, or says that the
-- value is not a capability at all.
local function describeCapability(capability: unknown): string
  if type(capability) == 'table' then
    local contract = rawget(capability :: { [string]: unknown }, 'contract')
    if type(contract) == 'string' then
      return 'capability ' .. contract
    end
  end
  return 'a value that is not a capability'
end

local function declaredField(declaration: Declaration, capability: unknown): string?
  for field, declared in declaration do
    if rawequal(declared, capability) then
      return field
    end
  end
  return nil
end

-- Returns the field a capability is declared under, or raises an error that
-- names the contract at the plugin code that passed it.
local function memberField(operation: string, declaration: Declaration, capability: unknown): string
  local field = declaredField(declaration, capability)
  if field == nil then
    error(string.format('plugin %s: %s is not declared', operation, describeCapability(capability)), 3)
  end
  return field
end

local function contractOf(declaration: Declaration, field: string): string
  return describeCapability(declaration[field])
end

local function unwrapDefinition<C>(definition: Definition<C>): NativeDefinition
  return ((definition :: unknown) :: DefinitionRecord<C>).nativeDefinition
end

-- The native context behind each wrapped context, keyed by the wrapper's
-- identity. A table a caller builds is not a key, so it cannot pose as an
-- owner; the native side then checks that the context is a live dependent.
local nativeContexts: { [Context]: NativeContext } = setmetatable({}, { __mode = 'k' }) :: any

local function ownerContext(owner: Owner, level: number): NativeContext
  local nativeContext = nativeContexts[(owner :: unknown) :: Context]
  if nativeContext == nil then
    error('plugin checkOwner: the owner is not a plugin context', level)
  end
  return nativeContext
end

local rejectUnknownFields = options.rejectUnknownFields

local subscriptionKeys: { [string]: boolean } = { event = true, run = true }

local function wrapContext(nativeContext: NativeContext, required: Declaration): Context
  local wrapped = {
    services = function(_self: Context): unknown
      return nativeContext:services()
    end,
    require = function<T>(_self: Context, capability: Capability<T>): T
      local field = memberField('require', required, capability)
      local services = (nativeContext:services() :: unknown) :: ErasedDeclaration
      return (services[field] :: unknown) :: T
    end,
    effect = function(_self: Owner, acquire: () -> () -> ()): Effect
      local effect: NativeEffect = nativeContext:effect(acquire)
      return (effect :: unknown) :: Effect
    end,
    child = function<C>(_self: Context, definition: Definition<C>, config: C): Instance<C>
      local instance: NativeInstance = nativeContext:child(unwrapDefinition(definition), config)
      instance:enable()
      return (instance :: unknown) :: Instance<C>
    end,
    checkOwner = function(_self: Context, caller: Owner): ()
      nativeContext:checkOwner(ownerContext(caller, 3))
    end,
    owns = function(_self: Context, caller: Owner): boolean
      local callerContext = nativeContexts[(caller :: unknown) :: Context]
      return callerContext ~= nil and nativeContext:owns(callerContext)
    end,
    acquire = function(_self: Context, owner: Owner, acquire: () -> () -> ()): Effect
      local callerContext = ownerContext(owner, 3)
      nativeContext:checkOwner(callerContext)
      local effect: NativeEffect = callerContext:effect(acquire)
      return (effect :: unknown) :: Effect
    end,
    on = function<E>(_self: Context, subscription: Subscription<E>): Effect
      if type(subscription) ~= 'table' then
        error('plugin on: a subscription is a table of fields, not a ' .. type(subscription), 2)
      end
      rejectUnknownFields('plugin on', subscription, subscriptionKeys, 'event and run', 2)
      local subscribe, handler = subscription.event, subscription.run
      if type(subscribe) ~= 'function' then
        error('plugin on: event is a subscribing function, not a ' .. type(subscribe), 2)
      end
      if type(handler) ~= 'function' then
        error('plugin on: run is a function, not a ' .. type(handler), 2)
      end
      local effect: NativeEffect = nativeContext:effect(function(): () -> ()
        -- An event delivered after the activation ended but before this
        -- inverse ran, such as an error reported during cleanup, is dropped.
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

local capabilityKeys: { [string]: boolean } = { name = true, schema = true }

-- Checks a capability spec's shape, raising at the caller of `plugin.capability`, three frames up.
local function validateCapabilitySpec(spec: CapabilitySpec): CapabilitySpec
  local level = 4
  if type(spec) ~= 'table' then
    error('plugin capability: a capability is a table of fields, not a ' .. type(spec), level)
  end
  local raw = (spec :: unknown) :: { [unknown]: unknown }
  rejectUnknownFields('plugin capability', raw, capabilityKeys, 'name and schema', level)
  local name = raw.name
  if type(name) ~= 'string' then
    error('plugin capability: name is a string, not a ' .. type(name), level)
  end
  if name == '' then
    error('plugin capability: name is empty', level)
  end
  local schema = raw.schema
  if type(schema) ~= 'number' then
    error('plugin capability: schema is a number, not a ' .. type(schema), level)
  end
  if schema ~= math.floor(schema) or schema < 1 or schema == math.huge then
    error('plugin capability: schema is a positive integer, not ' .. tostring(schema), level)
  end
  return { name = name, schema = schema }
end

function adapter.capability<T>(spec: CapabilitySpec): Capability<T>
  local fields = validateCapabilitySpec(spec)
  local token = native.plugin.contract(fields.name, fields.schema)
  local capability = freeze {
    token = token,
    witness = function(value: T): T
      return value
    end,
    contract = fields.name .. '@' .. tostring(fields.schema),
  }
  native.plugin.bind(token, capability)
  return capability
end

local function revoked(contract: string): string
  return 'plugin service: ' .. contract .. ' is no longer available because its provider activation has ended'
end

-- Wraps a published service in a frozen view. Every field read and every call
-- of a callable service checks that the provider's activation is still live,
-- and every write raises. A method is checked when it is read, so a method
-- call adds no stack frame and an error a provider raises at level 2 still
-- names the consumer's call site.
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

local function stagedValues(
  values: StagedValues,
  called: { [string]: boolean },
  provided: Declaration,
  provider: NativeContext
): StagedValues
  local result: StagedValues = {}
  for field, _ in provided do
    if not called[field] then
      error('plugin provision: missing provision ' .. field, 0)
    end
    local value = values[field]
    if value == nil then
      error('plugin provision: provision ' .. field .. ' was nil', 0)
    end
    result[field] = guardService(value, contractOf(provided, field), provider)
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

local specKeys: { [string]: boolean } = { name = true, requires = true, provides = true, init = true }

type ValidSpec<C> = {
  name: string,
  requires: Declaration,
  provides: Declaration,
  init: (Context, C, Publisher) -> (),
}

-- Checks a definition spec's shape and fills the optional declarations, raising at the caller of
-- `plugin.define`, three frames up.
local function validateSpec<C>(spec: Spec<C>): ValidSpec<C>
  local level = 4
  if type(spec) ~= 'table' then
    error('plugin define: a definition is a table of fields, not a ' .. type(spec), level)
  end
  local raw = (spec :: unknown) :: { [unknown]: unknown }
  rejectUnknownFields('plugin define', raw, specKeys, 'name, requires, provides, and init', level)
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
  local requires = raw.requires
  if requires ~= nil and type(requires) ~= 'table' then
    error('plugin define: requires is a table of capabilities, not a ' .. type(requires), level)
  end
  local provides = raw.provides
  if provides ~= nil and type(provides) ~= 'table' then
    error('plugin define: provides is a table of capabilities, not a ' .. type(provides), level)
  end
  return {
    name = name,
    requires = (requires or {}) :: Declaration,
    provides = (provides or {}) :: Declaration,
    init = spec.init,
  }
end

function adapter.define<C>(spec: Spec<C>): Definition<C>
  local fields = validateSpec(spec)
  local init = fields.init
  local requiredSnapshot = declarationSnapshot(fields.requires)
  local providedSnapshot = declarationSnapshot(fields.provides)
  local nativeDefinition = native.plugin.define(
    (requiredSnapshot :: unknown) :: ErasedDeclaration,
    (providedSnapshot :: unknown) :: ErasedDeclaration,
    function(nativeContext: NativeContext, config: unknown): unknown
      local staging: Staging = {
        open = true,
        active = function(): boolean
          return nativeContext:active()
        end,
        values = {},
        called = {},
      }
      -- The initializer is called unprotected so an error it raises keeps its
      -- own position and traceback. Staged values are released by this
      -- inverse when the load is rolled back, even if a publisher escaped.
      nativeContext:effect(function(): () -> ()
        return function(): ()
          staging.open = false
          staging.values = {}
          staging.called = {}
        end
      end)
      local context = wrapContext(nativeContext, requiredSnapshot)
      local typedConfig = (config :: unknown) :: C
      local provide = publisher(providedSnapshot, staging)
      local returned = select('#', init(context, typedConfig, provide))
      staging.open = false
      local values = staging.values
      local called = staging.called
      staging.values = {}
      staging.called = {}
      if returned ~= 0 then
        error('plugin provision: initializer must return nothing', 0)
      end
      return stagedValues(values, called, providedSnapshot, nativeContext)
    end,
    fields.name
  )
  return freeze {
    name = fields.name,
    requires = requiredSnapshot,
    provides = providedSnapshot,
    init = init,
    nativeDefinition = nativeDefinition,
  } :: Definition<C>
end

function adapter.runtime(): Runtime
  local nativeRuntime = native.plugin.runtime()
  local runtime = {
    use = function<C>(_self: Runtime, definition: Definition<C>, config: C): Instance<C>
      local instance: NativeInstance = nativeRuntime:use(unwrapDefinition(definition), config)
      return (instance :: unknown) :: Instance<C>
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
