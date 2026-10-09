-- Starts plugins for tests and boots compositions through LÖVR's callbacks.

local plugin = require '@lunette-plugin'
local compose = require '@lunette-plugin/compose'
local frame = require '@lunette-plugins/frame'
local drops = require '@lunette-contracts/drops'
local native = require '@testing/native'
local suite = require '@testing/suite'

local session = {}

local Session = {}
Session.__index = Session

local entryOf, startSession

-- Starts entries in a new runtime without installing the fake native API.
function session.start(entries)
  return startSession(entries, nil)
end

-- Installs the fake native API and binds LÖVR's callbacks for the session.
function session.boot(entries, options)
  local fake = options and options.native or native.new()
  local current
  frame.install {
    start = function() end,
    stop = function()
      current.runtime:close()
    end,
  }
  current = startSession(entries, fake)
  return current
end

function Session:use(definition, config)
  local instance = self.runtime:use(definition, config or {})
  instance:enable()
  return instance
end

-- Observes a service through a dependent plugin, refreshing the service and context after provider recovery.
function Session:observe(capability)
  self.observers += 1
  local observed = {}
  observed.instance = self:use(plugin.define {
    name = 'testing/observer-' .. self.observers,
    requires = { service = capability },
    init = function(context)
      observed.service = context:require(capability)
      observed.context = context
    end,
  })
  return observed
end

function Session:drop(surface)
  local observed = self.dropObserver
  if not observed then
    observed = self:observe(drops.capability)
    self.dropObserver = observed
  end
  observed.service:emit(observed.context, { surface = surface, pointer = {} })
end

function Session:update(dt)
  lovr.update(dt or 0.016)
end

function Session:draw()
  return lovr.draw(self.native.events.pass)
end

function Session:quit()
  return lovr.quit()
end

-- Closes the runtime and verifies release of native resources when the fake API is installed. A closed session
-- ignores a second close.
function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  self.runtime:close()
  if self.native then
    self.native.assertResourcesReleased()
  end
end

entryOf = function(entry)
  if type(entry) ~= 'string' then
    return entry
  end
  local module = require('@lunette-plugins/' .. entry)
  if type(module) == 'function' then
    return { id = entry, factory = module }
  elseif type(module) == 'table' and module.definition then
    return { id = entry, definition = module.definition }
  elseif type(module) == 'table' and module.factory then
    return { id = entry, factory = module.factory }
  end
  return { id = entry, definition = module }
end

startSession = function(entries, fake)
  local resolved = {}
  for index, entry in ipairs(entries) do
    resolved[index] = entryOf(entry)
  end
  local runtime = plugin.runtime()
  local instances = {}
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
