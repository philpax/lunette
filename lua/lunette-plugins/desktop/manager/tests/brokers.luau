local testing = require '@testing'
local plugin = require '@lunette-plugin'
local brokers = require '@lunette-plugins/desktop/manager/brokers'
local surfaces = require '@lunette-plugins/surfaces'
local expect = testing.expect
local test = testing.suite()

test('inspection children suspend independently of the manager owner', function()
  testing.native()
  local readers
  local manager = plugin.define {
    name = 'inspector-parent',
    init = function(context, _config, _publish)
      readers = brokers.watch(context)
    end,
  }
  local runtime = plugin.runtime()
  local source = runtime:use(surfaces.definition, {})
  local owner = runtime:use(manager, {})
  source:enable()
  owner:enable()
  runtime:drain()
  expect.equal(owner:state(), 'active', 'manager active with missing brokers')
  expect.equal(#readers, 16, 'every inspectable service represented')
  local initial = brokers.snapshot(readers)
  local surface
  local unavailable
  for _, broker in initial do
    if broker.name == 'surfaces' then
      surface = broker.snapshot
    elseif broker.name == 'panels' then
      unavailable = broker.snapshot
    end
  end
  expect.equal(surface.unobservable[1], 'offer results require callbacks', 'surface provider available')
  expect.equal(#unavailable.unobservable, 1, 'absent provider represented explicitly')
  source:disable()
  runtime:drain()
  expect.equal(owner:state(), 'active', 'parent survives provider outage')
  for _, broker in brokers.snapshot(readers) do
    if broker.name == 'surfaces' then
      expect.equal(broker.snapshot.unobservable[1], 'The inspection consumer has no active provider.', 'outage visible')
    end
  end
  expect.equal(surface.unobservable[1], 'offer results require callbacks', 'previous snapshot unchanged')
  source:enable()
  runtime:drain()
  for _, broker in brokers.snapshot(readers) do
    if broker.name == 'surfaces' then
      expect.equal(broker.snapshot.unobservable[1], 'offer results require callbacks', 'inspection reconnects')
    end
  end
  owner:disable()
  runtime:drain()
  for _, reader in readers do
    expect.equal(reader.inspect, nil, 'child release clears inspection capability')
  end
  runtime:close()
end)

return test
