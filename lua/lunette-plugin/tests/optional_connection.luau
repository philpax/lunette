local testing = require '@testing'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local expect = testing.expect
local test = testing.suite()

type Service = {
  read name: string,
  read acquire: (Service, plugin.Owner) -> plugin.Effect,
}

local capability = plugin.capability<<Service>> { name = 'test/optional-connection', version = 1 }
local other = plugin.capability<<Service>> { name = 'test/other-optional-connection', version = 1 }

local function provider(name: string, contract: plugin.Capability<Service>, released: { string }): plugin.Definition<{}>
  return plugin.provider<<{}, {}, Service>>({
    name = name,
    capability = contract,
    build = function(context: plugin.Context, _settings: {}): Service
      return {
        name = name,
        acquire = function(_self: Service, owner: plugin.Owner): plugin.Effect
          context:checkOwner(owner)
          return context:acquire(owner, function(): () -> ()
            return function(): ()
              table.insert(released, name)
            end
          end)
        end,
      }
    end,
  }).definition
end

test('an absent provider does not prevent the parent from starting, and a later provider connects', function()
  testing.native()
  local session = testing.start {}
  local read: (() -> plugin.Connection<Service>?)?
  local parentOwner: plugin.Context?
  local starts = 0
  local parent = session:use(adapter.define {
    name = 'optional-parent',
    init = function(context: plugin.Context)
      starts += 1
      parentOwner = context
      read = plugin.connectOptional(context, 'optional-child', capability)
    end,
  })
  expect.equal(parent:state(), 'active', 'the parent starts without the provider')
  expect.equal(assert(read)(), nil, 'there is no connection')
  local released: { string } = {}
  local source = session:use(provider('first', capability, released))
  local connected = assert(assert(read)())
  expect.equal(connected.service.name, 'first', 'the provider connects when it appears')
  expect.truthy(connected.owner ~= parentOwner, 'the child, not the parent, is the dependent owner')
  expect.raises(function()
    connected.service:acquire(assert(parentOwner))
  end, 'does not depend')
  connected.service:acquire(connected.owner)
  source:disable()
  expect.equal(assert(read)(), nil, 'provider loss clears the connection')
  expect.equal(table.concat(released, ','), 'first', 'the child releases its acquired resource')
  expect.equal(parent:state(), 'active', 'provider loss leaves the parent active')
  source:enable()
  local recovered = assert(assert(read)())
  expect.truthy(recovered.owner ~= connected.owner, 'recovery gets a new dependent owner')
  recovered.service:acquire(recovered.owner)
  source:requestReload {}
  session.runtime:drain()
  local reloaded = assert(assert(read)())
  expect.truthy(reloaded.owner ~= recovered.owner, 'reload replaces the child activation')
  expect.equal(#released, 2, 'reload releases the preceding activation resource')
  source:dispose()
  expect.equal(assert(read)(), nil, 'removal clears the connection')
  session:use(provider('replacement', capability, released))
  local replacement = assert(assert(read)())
  expect.equal(replacement.service.name, 'replacement', 'a replacement provider connects')
  replacement.service:acquire(replacement.owner)
  local oldRead = assert(read)
  parent:disable()
  expect.equal(oldRead(), nil, 'parent cleanup clears its connection')
  expect.equal(#released, 3, 'parent cleanup releases the child resource')
  parent:enable()
  expect.equal(starts, 2, 'only ending the parent restarts it')
  expect.truthy(assert(read)(), 'the new parent connects')
  expect.equal(oldRead(), nil, 'the old parent getter stays disconnected')
  session:close()
  expect.equal(assert(read)(), nil, 'runtime shutdown clears the connection')
end)

test("optional capabilities have independent children and survive each other's outages", function()
  testing.native()
  local session = testing.start {}
  local first: (() -> plugin.Connection<Service>?)?
  local second: (() -> plugin.Connection<Service>?)?
  local parent = session:use(adapter.define {
    name = 'independent-parent',
    init = function(context: plugin.Context)
      first = plugin.connectOptional(context, 'first-child', capability)
      second = plugin.connectOptional(context, 'second-child', other)
    end,
  })
  local source = session:use(provider('first', capability, {}))
  local connected = assert(assert(first)())
  expect.equal(assert(second)(), nil, 'the missing second capability does not prevent the first connection')
  session:use(provider('second', other, {}))
  local independent = assert(assert(second)())
  expect.truthy(connected.owner ~= independent.owner, 'each capability has its own dependent child')
  source:disable()
  expect.equal(assert(first)(), nil, 'the lost capability disconnects')
  expect.equal(assert(second)(), independent, 'the other connection keeps its activation')
  expect.equal(parent:state(), 'active', 'the parent remains active')
  session:close()
end)

return test
