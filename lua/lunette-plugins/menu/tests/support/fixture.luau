local testing = require '@testing'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local contract = require '@lunette-contracts/menu'

local fixture = {}

type Native = testing.Native
type Session = testing.Session
type Observed = testing.Observed<contract.Service>
export type Environment = {
  native: Native,
  session: Session,
  observed: Observed,
  service: contract.Service,
  owner: plugin.Context,
}
export type Probe = { owner: plugin.Context?, service: contract.Service?, instance: adapter.Instance<{}>? }

function fixture.start(): Environment
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

function fixture.probe(env: Environment, name: string): Probe
  local found: Probe = {}
  found.instance = env.session:use(adapter.define {
    name = name,
    requires = { contract.capability },
    init = function(context: plugin.Context)
      found.owner = context
      found.service = context:require(contract.capability)
    end,
  })
  return found
end

function fixture.action(id: string, run: (() -> ())?): contract.Action
  return { id = id, label = 'Action ' .. id, run = run or function() end }
end

return fixture
