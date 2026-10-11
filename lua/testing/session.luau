-- Starts plugins for tests and boots compositions through LÖVR's callbacks.

local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local compose = require '@lunette-plugin/compose'
local frame = require '@lunette-plugins/frame'
local drops = require '@lunette-contracts/drops'
local native = require '@testing/native'
local suite = require '@testing/suite'

local session = {}

export type Entry = string | compose.Entry
export type ComposeEntry = compose.Entry
export type Patch = compose.Patch
export type Context = adapter.Context
export type Owner = plugin.Owner
export type Effect = plugin.Effect
export type Definition<C> = adapter.Definition<C>
export type InspectionSnapshot = typeof(require('@lunette-contracts/inspection').snapshot {})
export type InspectionDetails = typeof(require('@lunette-contracts/inspection').snapshot({}).state)
export type InspectionRegistration = typeof(require('@lunette-contracts/inspection').snapshot({}).registrations[1])
export type Options = { read native: native.Fake? }
export type Observed<T> = {
  instance: adapter.Instance<compose.Config>?,
  service: T?,
  context: adapter.Context?,
}
export type Session = {
  runtime: adapter.Runtime,
  instances: { [string]: adapter.Instance<compose.Config> },
  native: native.Fake?,
  observers: number,
  closed: boolean,
  dropObserver: Observed<drops.Service>?,
  use: <C>(Session, adapter.Definition<C>, C?) -> adapter.Instance<C>,
  observe: <T>(Session, adapter.Capability<T>) -> Observed<T>,
  drop: (Session, drops.Surface) -> (),
  update: (Session, number?) -> (),
  draw: (Session) -> boolean,
  quit: (Session) -> boolean,
  close: (Session) -> (),
}

local Session = {}
Session.__index = Session

local entryOf: (Entry) -> compose.Entry
local startSession: ({ Entry }, native.Fake?) -> Session

-- Starts entries in a new runtime without installing the fake native API.
function session.start(entries: { Entry }): Session
  return startSession(entries, nil)
end

-- Installs the fake native API and binds LÖVR's callbacks for the session.
function session.boot(entries: { Entry }, options: Options?): Session
  local fake = options and options.native or native.new()
  local current: Session
  frame.install {
    start = function() end,
    stop = function()
      current.runtime:close()
    end,
  }
  current = startSession(entries, fake)
  return current
end

function Session.use<C>(self: Session, definition: adapter.Definition<C>, config: C?): adapter.Instance<C>
  local instance = self.runtime:use(definition, config or {})
  instance:enable()
  return instance
end

-- Observes a service through a dependent plugin, refreshing the service and context after provider recovery.
function Session.observe<T>(self: Session, capability: adapter.Capability<T>): Observed<T>
  self.observers += 1
  local observed: Observed<T> = {}
  observed.instance = self:use(adapter.define {
    name = 'testing/observer-' .. self.observers,
    requires = { capability },
    init = function(context: adapter.Context)
      observed.service = context:require(capability)
      observed.context = context
    end,
  })
  return observed
end

function Session.drop(self: Session, surface: drops.Surface)
  local observed = self.dropObserver
  if not observed then
    observed = self:observe(drops.capability)
    self.dropObserver = observed
  end
  observed.service:emit(observed.context, { surface = surface, pointer = {} })
end

function Session.update(self: Session, dt: number?)
  lovr.update(dt or 0.016)
end

function Session.draw(self: Session): boolean
  return lovr.draw(self.native.events.pass)
end

function Session.quit(self: Session): boolean
  return lovr.quit()
end

-- Closes the runtime and verifies release of native resources when the fake API is installed. A closed session
-- ignores a second close.
function Session.close(self: Session)
  if self.closed then
    return
  end
  self.closed = true
  self.runtime:close()
  if self.native then
    self.native.assertResourcesReleased()
  end
end

entryOf = function(entry: Entry): compose.Entry
  if type(entry) ~= 'string' then
    return entry
  end
  return { id = entry, definition = require('@lunette-plugins/' .. entry).definition }
end

startSession = function(entries: { Entry }, fake: native.Fake?): Session
  local resolved: { compose.Entry } = {}
  for index, entry in ipairs(entries) do
    resolved[index] = entryOf(entry)
  end
  local runtime = adapter.runtime()
  local instances: { [string]: adapter.Instance<compose.Config> } = {}
  local ok, failure = pcall(function()
    for _, entry in ipairs(plugin.compose(resolved)) do
      local source = compose.resolveEntry(entry)
      local instance = runtime:use(source.definition, source.config)
      instances[entry.id] = instance
      instance:enable()
    end
    runtime:drain()
  end)
  if not ok then
    runtime:close()
    error(failure, 0)
  end
  local started = setmetatable({
    runtime = runtime,
    instances = instances,
    native = fake,
    observers = 0,
    closed = false,
  }, Session)
  suite.opened(started)
  return started
end

return session
