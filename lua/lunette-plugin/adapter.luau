-- The adapter maps typed plugin declarations to native runtime handles.

local native = require '@lunette'
local options = require '@lunette-plugin/options'
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
  read schema: number,
}

export type Effect = {
  read dispose: (Effect) -> (),
}

-- An owner releases each acquired effect when its activation ends.
export type Owner = {
  read services: (never) -> unknown,
  read effect: (Owner, () -> () -> ()) -> Effect,
}

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
  read acquireDeferred: (Context, Owner, () -> () -> ()) -> Effect,
  read resource: <T>(Context, Owner, () -> (T, () -> ())) -> (T, Effect),
  read on: <E>(Context, Subscription<E>) -> Effect,
  read active: (Context) -> boolean,
}

export type Publisher = {
  read provide: <T>(Publisher, Capability<T>, T) -> (),
}

export type Declaration = { [string]: { read witness: (never) -> unknown } }

export type Spec<C> = {
  read name: string,
  read requires: Declaration?,
  read provides: Declaration?,
  read init: (Context, C, Publisher) -> (),
}

-- The context and publisher use `never` to avoid recursive types.
-- A recursive `Context` type prevents `Context:child` from checking its configuration against `C`.
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
  read reload: (Instance<C>, C) -> (),
  read requestReload: (Instance<C>, C) -> (),
  read state: (Instance<C>) -> native.PluginState,
  read diagnostic: (Instance<C>) -> string?,
}

export type Runtime = {
  read use: <C>(Runtime, Definition<C>, C) -> Instance<C>,
  read snapshot: (Runtime) -> native.PluginRuntimeSnapshot,
  read owns: <C>(Runtime, Instance<C>) -> boolean,
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

local function declarationSnapshot(value: Declaration): Declaration
  return freeze(table.clone(value))
end

-- Native validation rejects any value that is not a token, so a value without one passes through unchanged.
local function declarationTokens(declaration: Declaration): ErasedDeclaration
  local tokens: ErasedDeclaration = {}
  for field, capability in declaration do
    tokens[field] = if type(capability) == 'table' then rawget(capability :: any, 'token') or capability else capability
  end
  return tokens
end

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
    acquireDeferred = function(_self: Context, owner: Owner, acquire: () -> () -> ()): Effect
      local callerContext = ownerContext(owner, 3)
      nativeContext:checkOwner(callerContext)
      local effect: NativeEffect = callerContext:effectDeferred(acquire)
      return (effect :: unknown) :: Effect
    end,
    resource = function<T>(_self: Context, owner: Owner, acquire: () -> (T, () -> ())): (T, Effect)
      local callerContext = ownerContext(owner, 3)
      if callerContext ~= nativeContext then
        nativeContext:checkOwner(callerContext)
      end
      local value: T
      local effect: NativeEffect = callerContext:effect(function(): () -> ()
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
      rejectUnknownFields('plugin on', subscription, subscriptionKeys, 'event and run', 2)
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

local capabilityKeys: { [string]: boolean } = { name = true, schema = true }

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
  return freeze {
    token = native.plugin.contract(fields.name, fields.schema),
    witness = function(value: T): T
      return value
    end,
    contract = fields.name .. '@' .. tostring(fields.schema),
  }
end

local function revoked(contract: string): string
  return 'plugin service: ' .. contract .. ' is no longer available because its provider activation has ended'
end

-- Service reads, iteration, and calls to function-valued services raise after the provider activation ends.
-- A previously read method remains callable. Guarding the read preserves the provider error's call site.
-- Writes always raise.
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
local function stagedValues(values: StagedValues, provided: Declaration, provider: NativeContext): StagedValues
  local result: StagedValues = {}
  for field, value in values do
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

-- Records every definition `define` made, so a forged table is not accepted as one.
local definitions: { [unknown]: boolean } = setmetatable({}, { __mode = 'k' }) :: any

function adapter.isDefinition(value: unknown): boolean
  return definitions[value] == true
end

function adapter.define<C>(spec: Spec<C>, configuration: Configuration?): Definition<C>
  local fields = validateSpec(spec)
  local init = fields.init
  local requiredSnapshot = declarationSnapshot(fields.requires)
  local providedSnapshot = declarationSnapshot(fields.provides)
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
      ownerLabels[context] = fields.name
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
      return stagedValues(values, providedSnapshot, nativeContext)
    end,
    fields.name
  )
  local definition = freeze {
    name = fields.name,
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
    owns = function<C>(_self: Runtime, instance: Instance<C>): boolean
      return nativeRuntime:owns((instance :: unknown) :: NativeInstance)
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
