-- Starting plugins for a test: `start` for a few plugins in a runtime of their own, and `boot` for a
-- composition driven through LÖVR's callbacks, as the desktop runs.
--
-- Both take a list of entries in the composition's shape, `{ id, definition | factory, config }`, so a test
-- starts exactly the plugins it names. An entry may also be a string, the path of a built-in plugin under
-- `@lunette-plugins`: `'panels'` is `{ id = 'panels', definition = require('@lunette-plugins/panels').definition }`.
-- Both answer a session, whose `observe` reaches a contract's service as a plugin of its own and stays
-- current across the provider's outages.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local drops = require '@lunette-contracts/drops'
local native = require '@testing/native'

local session = {}

local Session = {}
Session.__index = Session

-- Defined below the public functions, in the order they use them.
local entryOf, startSession

-- Starts `entries` in a new runtime, enabling each in order, and answers the session. Nothing is installed
-- on `@lunette` or `lovr`; a test that needs the fake native API calls `testing.native()` first.
function session.start(entries)
  return startSession(entries, nil)
end

-- Installs a fake native API, or `options.native` when given, binds LÖVR's callbacks through
-- `frame.install`, starts `entries`, and answers the session. `session.native` is the fake, and
-- `session:update`, `session:draw`, and `session:quit` call the bound callbacks.
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

-- Enables `definition` with `config` in the session's runtime and answers its instance.
function Session:use(definition, config)
  local instance = self.runtime:use(definition, config or {})
  instance:enable()
  return instance
end

-- A plugin of its own requiring `capability`, answered as `{ service, context, instance }`. The service and
-- context are replaced each time the plugin activates again, so the answer stays current after the provider
-- returns from an outage.
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

-- Announces that a grab let go of `surface`, as interaction does.
function Session:drop(surface)
  local observed = self.dropObserver
  if not observed then
    observed = self:observe(drops.capability)
    self.dropObserver = observed
  end
  observed.service:emit(observed.context, { surface = surface, pointer = {} })
end

-- Runs the bound `lovr.update` once, by `dt` or a 60 Hz frame.
function Session:update(dt)
  lovr.update(dt or 0.016)
end

-- Runs the bound `lovr.draw` with the fake's pass, and answers what it answers.
function Session:draw()
  return lovr.draw(self.native.events.pass)
end

-- Runs the bound `lovr.quit`, and answers what it answers.
function Session:quit()
  return lovr.quit()
end

-- Closes the runtime and, with a fake native API, raises unless every native resource was released.
function Session:close()
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
  local running = plugin.start(resolved)
  return setmetatable({
    runtime = running.runtime,
    instances = running.instances,
    native = fake,
    observers = 0,
  }, Session)
end

return session
