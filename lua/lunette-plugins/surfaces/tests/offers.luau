local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local surfacesContract = require '@lunette-contracts/surfaces'

local test = testing.suite()

local function consumer(session, name, register)
  local instance = session:use(plugin.define {
    name = name,
    requires = { surfaces = surfacesContract.capability },
    init = function(context)
      register(context, context:require(surfacesContract.capability))
    end,
  })
  expect.equal(instance:state(), 'active', name)
  return instance
end

local function listing(label)
  return function()
    return { { dead = false, raycast = function() end, label = label } }
  end
end

test('an offer name names one offer until its effect or its owner ends, and offers list in order', function()
  local session = testing.start { 'surfaces' }
  local broker
  local first = consumer(session, 'surfaces-first', function(context, service)
    broker = service
    service:offer(context, { name = 'fixture', list = listing 'first' })
  end)
  local offered
  consumer(session, 'surfaces-second', function(context, service)
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
  consumer(session, 'surfaces-reuse', function(context, service)
    service:offer(context, { name = 'fixture', list = listing 'reused' })
  end)
  expect.equal(broker:all()[1].label, 'reused', 'the freed name is offered again')
  session:close()
end)

test('a malformed offer raises at the call', function()
  local session = testing.start { 'surfaces' }
  consumer(session, 'surfaces-checks', function(context, service)
    expect.raises(function()
      service:offer(context, { name = 'unlisted' })
    end, 'surfaces offer: list is a function, not a nil', 'an offer without a list')
    expect.raises(function()
      service:offer(context, { name = '', list = function() end })
    end, 'surfaces offer: name is a non%-empty string', 'an empty name')
  end)
  session:close()
end)

return test
