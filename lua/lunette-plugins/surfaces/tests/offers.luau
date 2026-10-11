local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local surfacesContract = require '@lunette-contracts/surfaces'

local test = testing.suite()

type Session = typeof(testing.start {})
type ListedSurface = { read dead: boolean, read raycast: () -> (), read label: string }

local function consumer(
  session: Session,
  name: string,
  register: (plugin.Context, surfacesContract.Service) -> ()
): adapter.Instance<{}>
  local instance = session:use(adapter.define {
    name = name,
    requires = { surfacesContract.capability },
    init = function(context: plugin.Context)
      register(context, context:require(surfacesContract.capability))
    end,
  })
  expect.equal(instance:state(), 'active', name)
  return instance
end

local function listing(label: string): () -> { ListedSurface }
  return function(): { ListedSurface }
    return { { dead = false, raycast = function() end, label = label } }
  end
end

test('an offer name names one offer until its effect or its owner ends, and offers list in order', function()
  local session = testing.start { 'surfaces' }
  local broker: surfacesContract.Service?
  local first = consumer(session, 'surfaces-first', function(context: plugin.Context, service: surfacesContract.Service)
    broker = service
    service:offer(context, { name = 'fixture', list = listing 'first' })
  end)
  local offered: plugin.Effect?
  consumer(session, 'surfaces-second', function(context: plugin.Context, service: surfacesContract.Service)
    expect.raises(function()
      service:offer(context, { name = 'fixture', list = function() end })
    end, 'surfaces offer: fixture is already registered', 'a name already offered')
    offered = service:offer(context, { name = 'second', list = listing 'second' })
  end)
  local listed = broker:all()
  expect.equal(#listed, 2, 'the offered surfaces')
  expect.equal(listed[1].label, 'first', 'the first offer lists first')
  expect.equal(listed[2].label, 'second', 'the second offer lists second')
  offered:dispose()
  expect.equal(#broker:all(), 1, 'the surfaces after the effect ends')
  first:disable()
  expect.equal(#broker:all(), 0, 'the surfaces after the owner ends')
  consumer(session, 'surfaces-reuse', function(context: plugin.Context, service: surfacesContract.Service)
    service:offer(context, { name = 'fixture', list = listing 'reused' })
  end)
  expect.equal(broker:all()[1].label, 'reused', 'the freed name is offered again')
  session:close()
end)

return test
