-- The erased boundary for plugin declarations and native runtime handles.
--
-- Public types retain capability and configuration relationships. Runtime
-- declarations retain frozen capability wrappers so native validation and
-- per-capability access both use the exact wrapper registered at binding.

local native = require '@lunette'

local adapter = {}

type NativeContext = native.PluginContext
type NativeDefinition = native.PluginDefinition
type NativeEffect = native.PluginEffect
type NativeInstance = native.PluginInstance

export type Capability<T> = {
  read witness: (T) -> T,
}

export type Effect = {
  read dispose: (Effect) -> (),
}

export type Owner = {
  read services: (never) -> unknown,
  read effect: (Owner, () -> () -> ()) -> Effect,
}

export type Context = {
  read services: (never) -> unknown,
  read require: <T>(Context, Capability<T>) -> T,
  read effect: (Owner, () -> () -> ()) -> Effect,
  read child: <C>(Context, Definition<C>, C) -> Instance<C>,
  read checkOwner: (Context, Owner) -> (),
  read active: (Context) -> boolean,
}

export type Publisher = {
  read provide: <T>(Publisher, Capability<T>, T) -> (),
}

export type Declaration = { [string]: { read witness: (never) -> unknown } }

export type Definition<C> = {
  read configWitness: (C) -> C,
  read required: Declaration,
  read provided: Declaration,
}

type DefinitionRecord<C> = Definition<C> & {
  read nativeDefinition: NativeDefinition,
}

export type Instance<C> = {
  read enable: (Instance<C>) -> (),
  read disable: (Instance<C>) -> (),
  read dispose: (Instance<C>) -> (),
  read reload: (Instance<C>, C) -> (),
}

export type Runtime = {
  read use: <C>(Runtime, Definition<C>, C) -> Instance<C>,
  read close: (Runtime) -> (),
  read drain: (Runtime) -> (),
}

type ContextRecord = Context & {
  read nativeContext: NativeContext,
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

local function mapDeclaration(declaration: Declaration): ErasedDeclaration
  local mapped: ErasedDeclaration = {}
  for field, capability in declaration do
    mapped[field] = capability
  end
  return freeze(mapped)
end

local function declaredField(declaration: Declaration, capability: unknown): string
  for field, declared in declaration do
    if rawequal(declared, capability) then
      return field
    end
  end
  error 'plugin capability: capability is not declared'
end

local function unwrapDefinition<C>(definition: Definition<C>): NativeDefinition
  return ((definition :: unknown) :: DefinitionRecord<C>).nativeDefinition
end

local function wrapContext(nativeContext: NativeContext, required: Declaration): Context
  local wrapped = {
    nativeContext = nativeContext,
    services = function(_self: Context): unknown
      return nativeContext:services()
    end,
    require = function<T>(_self: Context, capability: Capability<T>): T
      local field = declaredField(required, capability)
      local services = (nativeContext:services() :: unknown) :: ErasedDeclaration
      return (services[field] :: unknown) :: T
    end,
    effect = function(_self: Owner, acquire: () -> () -> ()): Effect
      local effect: NativeEffect = nativeContext:effect(acquire)
      return (effect :: unknown) :: Effect
    end,
    child = function<C>(_self: Context, definition: Definition<C>, config: C): Instance<C>
      local instance: NativeInstance = nativeContext:child(unwrapDefinition(definition), config)
      return (instance :: unknown) :: Instance<C>
    end,
    checkOwner = function(_self: Context, caller: Owner): ()
      nativeContext:checkOwner(((caller :: unknown) :: ContextRecord).nativeContext)
    end,
    active = function(_self: Context): boolean
      return nativeContext:active()
    end,
  }
  return (freeze(wrapped) :: unknown) :: Context
end

function adapter.capability<T>(token: native.PluginContractToken, witness: (T) -> T): Capability<T>
  local capability = freeze { token = token, witness = witness }
  native.plugin.bind(token, capability)
  return capability
end

local function stagedValues(values: StagedValues, called: { [string]: boolean }, provided: Declaration): StagedValues
  local result: StagedValues = {}
  for field, _ in provided do
    if not called[field] then
      error('plugin provision: missing provision ' .. field)
    end
    local value = values[field]
    if value == nil then
      error('plugin provision: provision ' .. field .. ' was nil')
    end
    result[field] = value
  end
  return result
end

local function publisher(provided: Declaration, staging: Staging): Publisher
  return freeze {
    provide = function<T>(_self: Publisher, capability: Capability<T>, value: T): ()
      if not staging.open or not staging.active() then
        error 'plugin provision: initializer is no longer active'
      end
      local field = declaredField(provided, capability)
      if staging.called[field] then
        error('plugin provision: duplicate provision ' .. field)
      end
      if value == nil then
        error('plugin provision: provision ' .. field .. ' was nil')
      end
      staging.called[field] = true
      staging.values[field] = value
    end,
  }
end

function adapter.define<C>(
  configWitness: (C) -> C,
  required: Declaration,
  provided: Declaration,
  init: (Context, C, Publisher) -> ()
): Definition<C>
  local requiredSnapshot = declarationSnapshot(required)
  local providedSnapshot = declarationSnapshot(provided)
  local nativeDefinition = native.plugin.define(
    mapDeclaration(requiredSnapshot),
    mapDeclaration(providedSnapshot),
    function(nativeContext: NativeContext, config: unknown): unknown
      local staging: Staging = {
        open = true,
        active = function(): boolean
          return nativeContext:active()
        end,
        values = {},
        called = {},
      }
      local context = wrapContext(nativeContext, requiredSnapshot)
      local typedConfig = (config :: unknown) :: C
      local provide = publisher(providedSnapshot, staging)
      local results = table.pack(pcall(function(): ...unknown
        return init(context, typedConfig, provide)
      end))
      staging.open = false
      local values = staging.values
      local called = staging.called
      staging.values = {}
      staging.called = {}
      if not results[1] then
        error(results[2])
      end
      if results.n ~= 1 then
        error 'plugin provision: initializer must return nothing'
      end
      return stagedValues(values, called, providedSnapshot)
    end
  )
  return freeze {
    configWitness = configWitness,
    required = requiredSnapshot,
    provided = providedSnapshot,
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
