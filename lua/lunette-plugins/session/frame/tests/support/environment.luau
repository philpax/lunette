-- Starts the frame provider with the fake native API and owner-scoped consumers.
local testing = require '@testing'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local frame = require '../../'
local frameContract = require '@lunette-contracts/frame'

local environment = {}

export type Environment = { native: testing.Native, stopped: number, session: testing.Session? }
export type Register = (plugin.Context, frameContract.Service) -> ()

function environment.start(): Environment
  local env: Environment = { native = testing.native(), stopped = 0 }
  frame.install {
    start = function() end,
    stop = function()
      env.stopped += 1
      env.session.runtime:close()
    end,
  }
  env.session = testing.start { 'frame' }
  env.session.native = env.native
  return env
end

function environment.consumer(env: Environment, name: string, register: Register): adapter.Instance<{}>
  return env.session:use(adapter.define {
    name = name,
    requires = { frameContract.capability },
    init = function(context: plugin.Context)
      register(context, context:require(frameContract.capability))
    end,
  })
end

return environment
