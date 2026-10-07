local testing = require '@testing'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/menu'

local fixture = {}

function fixture.start()
  local native = testing.native()
  local session = testing.start { 'menu' }
  local observed = session:observe(contract.capability)
  return {
    native = native,
    session = session,
    observed = observed,
    service = observed.service,
    owner = observed.context,
  }
end

function fixture.probe(env, name, init)
  local found = {}
  found.instance = env.session:use(plugin.define {
    name = name,
    requires = { menu = contract.capability },
    init = function(context)
      found.owner = context
      found.service = context:require(contract.capability)
      if init then
        init(found)
      end
    end,
  })
  return found
end

function fixture.action(id, run)
  return { id = id, label = 'Action ' .. id, run = run or function() end }
end

return fixture
