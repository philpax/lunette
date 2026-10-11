local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local errorsContract = require '@lunette-contracts/errors'

local test = testing.suite()

type Environment = {
  native: typeof(testing.native()),
  heard: { errorsContract.Report },
  session: typeof(testing.start {})?,
  presenter: adapter.Definition<{}>?,
  service: errorsContract.Service?,
  owner: adapter.Context?,
}

local function start(): Environment
  local env: Environment = { native = testing.native(), heard = {} }
  env.session = testing.start { 'errors' }
  env.presenter = adapter.define {
    name = 'presenter',
    requires = { errorsContract.capability },
    init = function(context: adapter.Context)
      env.service, env.owner = context:require(errorsContract.capability), context
      env.service:onReport(context, {
        run = function(report: errorsContract.Report)
          env.heard[#env.heard + 1] = report
        end,
      })
    end,
  }
  env.session:use(env.presenter)
  return env
end

test('a native error reaches every listener as a report with its text and sequence', function()
  local env = start()
  local logged = env.native.raise('callback failed', 'traceback one')
  expect.truthy(logged:find('callback failed', 1, true), 'the boundary logs the error: ' .. logged)
  expect.equal(#env.heard, 1, 'the reports heard')
  local report = env.heard[1]
  expect.truthy(report.sequence == 1 and report.suppressed == 0, 'the sequence and suppression')
  expect.equal(report.text, 'callback failed\ntraceback one', 'the text')
  expect.equal(env.service:latest(), report, 'the latest report for a presenter that starts late')
  env.session:close()
end)

test('a repeat within the window is withheld and counted on the next delivery', function()
  local env = start()
  env.native.raise('callback failed', 'traceback one')
  env.native.raise('callback failed', 'traceback one')
  expect.equal(#env.heard, 1, 'a repeat within the window is withheld')
  env.native.events.time = 6
  env.native.raise('callback failed', 'traceback one')
  expect.equal(#env.heard, 2, 'the repeat after the window')
  expect.equal(env.heard[2].suppressed, 1, 'the count of withheld repeats')
  expect.truthy(env.heard[2].text:find('1 identical error was suppressed', 1, true), env.heard[2].text)
  env.session:close()
end)

return test
