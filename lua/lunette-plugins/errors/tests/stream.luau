local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local errorsContract = require '@lunette-contracts/errors'
local errors = require '@lunette-plugins/errors'

local test = testing.suite()

local function start()
  local env = { native = testing.native(), now = 0, heard = {}, cleared = 0 }
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
  env.presenter = plugin.define {
    name = 'presenter',
    requires = { errors = errorsContract.capability },
    init = function(context)
      env.service, env.owner = context:require(errorsContract.capability), context
      env.service:subscribe(context, {
        run = function(report)
          env.heard[#env.heard + 1] = report
        end,
        cleared = function()
          env.cleared += 1
        end,
      })
    end,
  }
  env.session:use(env.presenter)
  return env
end

test('a native error reaches every subscriber as a frozen report with its text and sequence', function()
  local env = start()
  local logged = env.native.raise('callback failed', 'traceback one')
  expect.truthy(logged:find('callback failed', 1, true), 'the boundary logs the error: ' .. logged)
  expect.equal(#env.heard, 1, 'the reports heard')
  local report = env.heard[1]
  expect.truthy(report.sequence == 1 and report.suppressed == 0, 'the sequence and suppression')
  expect.equal(report.text, 'callback failed\ntraceback one', 'the text')
  expect.raises(function()
    report.text = 'changed'
  end, nil, 'a report is frozen')
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

test('the history is bounded and oldest first, and clearing it tells every subscriber', function()
  local env = start()
  for index = 1, 4 do
    env.native.raise('failure ' .. index, 'traceback ' .. index)
  end
  local recent = env.service:recent()
  expect.equal(#recent, 3, 'the bounded history')
  expect.truthy(recent[1].sequence == 2 and recent[3].message == 'failure 4', 'oldest first')
  env.service:clear(env.owner)
  expect.equal(#env.service:recent(), 0, 'the history after clearing')
  expect.equal(env.cleared, 1, 'the subscribers told')
  env.native.raise('after clearing', 'traceback')
  expect.equal(env.heard[#env.heard].sequence, 1, 'the sequence restarts after a clear')
  env.session:close()
end)

test('a raising subscriber is reported, and its report joins the history without being delivered again', function()
  local env = start()
  local raising = env.session:use(plugin.define {
    name = 'raising-presenter',
    requires = { errors = errorsContract.capability },
    init = function(context)
      context:require(errorsContract.capability):subscribe(context, {
        run = function()
          error 'presenter failure'
        end,
      })
    end,
  })
  env.native.raise('native failure', 'traceback')
  expect.equal(#env.heard, 1, 'the other subscriber hears the report once')
  local recent = env.service:recent()
  expect.equal(#recent, 2, 'the history')
  expect.truthy(recent[2].message:find('presenter failure', 1, true), 'the subscriber failure joins the history')
  raising:dispose()
  env.session:close()
end)

test('a malformed subscriber raises at the call', function()
  local env = start()
  expect.raises(function()
    env.service:subscribe(env.owner, { run = function() end, colour = true })
  end, nil, 'an unknown field')
  env.session:close()
end)

test('disabling the stream ends its subscription and service, and a new activation starts empty', function()
  local env = start()
  env.native.raise('before', 'traceback')
  local first = env.service
  env.session.instances.errors:disable()
  expect.equal(env.native.subscriptionCount 'onError', 0, 'the native subscription')
  expect.raises(function()
    first:recent()
  end, nil, 'the service of the ended activation')
  expect.truthy(env.native.raise('unpresented', 'traceback'):find('unpresented', 1, true), 'the boundary still logs')

  env.session.instances.errors:enable()
  expect.equal(#env.service:recent(), 0, 'a new activation starts with an empty history')
  env.native.raise('fresh', 'traceback')
  expect.equal(env.heard[#env.heard].sequence, 1, 'the sequence of the new activation')
  env.session:close()
end)

test('a malformed option fails the activation and is reported', function()
  local env = start()
  env.session.instances.errors:disable()
  local bad = env.session.runtime:use(errors.definition, { history = 0 })
  bad:enable()
  expect.equal(bad:state(), 'failed', 'the activation')
  local reports = testing.takeReports()
  expect.equal(#reports, 1, 'the reports')
  expect.truthy(reports[1]:find('plugin errors: option ', 1, true), reports[1])
  bad:dispose()
  env.session:close()
end)

return test
