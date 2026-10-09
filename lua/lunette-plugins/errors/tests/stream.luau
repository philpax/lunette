local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local errorsContract = require '@lunette-contracts/errors'
local errors = require '@lunette-plugins/errors'

local test = testing.suite()

local function start()
  local env = { native = testing.native(), now = 0, heard = {} }
  env.session = testing.start {
    {
      id = 'errors',
      definition = errors.definition,
      config = {
        history = 3,
        clock = function()
          return env.now
        end,
      },
    },
  }
  env.presenter = adapter.define {
    name = 'presenter',
    requires = { errorsContract.capability },
    init = function(context)
      env.service, env.owner = context:require(errorsContract.capability), context
      env.service:onReport(context, {
        run = function(report)
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
  env.session:close()
end)

test('a repeat within the window is withheld and counted on the next delivery', function()
  local env = start()
  env.native.raise('callback failed', 'traceback one')
  env.native.raise('callback failed', 'traceback one')
  expect.equal(#env.heard, 1, 'a repeat within the window is withheld')
  env.now = 6
  env.native.raise('callback failed', 'traceback one')
  expect.equal(#env.heard, 2, 'the repeat after the window')
  expect.equal(env.heard[2].suppressed, 1, 'the count of withheld repeats')
  expect.truthy(env.heard[2].text:find('1 identical error was suppressed', 1, true), env.heard[2].text)
  env.session:close()
end)

test('the history is bounded and oldest first', function()
  local env = start()
  for index = 1, 4 do
    env.native.raise('failure ' .. index, 'traceback ' .. index)
  end
  local recent = env.service:recent()
  expect.equal(#recent, 3, 'the bounded history')
  expect.truthy(recent[1].sequence == 2 and recent[3].message == 'failure 4', 'oldest first')
  env.session:close()
end)

return test
