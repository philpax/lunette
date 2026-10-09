local testing = require '@testing'
local expect = testing.expect
local rulesContract = require '@lunette-contracts/rules'

local test = testing.suite()

local function start()
  local session = testing.start { 'rules' }
  local observed = session:observe(rulesContract.capability)
  local window = { id = 1, dead = false, width = 800, height = 600, appId = 'fixture', title = 'Fixture' }
  return session, observed.service, observed.context, window
end

test('a rule matches by value or predicate, and where over the whole window', function()
  local session, rules, owner, window = start()
  local matching = rules:setRules(owner, {
    name = 'matching',
    precedence = 100,
    rules = {
      {
        match = {
          appId = function(value, source)
            return value == source.appId
          end,
          title = 'Fixture',
        },
        properties = { width = 1 },
      },
      {
        match = {
          where = function(source)
            return source == window
          end,
        },
        properties = { height = 2 },
      },
      {
        match = {
          appId = window.appId,
          where = function()
            return false
          end,
        },
        properties = { chrome = true },
      },
    },
  })
  local resolved = rules:resolve(window)
  expect.equal(resolved.width, 1, 'a predicate and a literal')
  expect.equal(resolved.height, 2, 'where receives the window')
  expect.equal(resolved.chrome, nil, 'where refusing overrides a matching field')
  expect.raises(function()
    rules:setRules(owner, { rules = { { match = { typo = true } } } })
  end, 'unsupported match field typo', 'an unsupported match key')
  matching:dispose()
  session:close()
end)

test('a higher precedence source wins a key, and only the winning evaluator is called', function()
  local session, rules, owner, window = start()
  local literal = function()
    error 'literal extension called'
  end
  local payload = { nested = { 1, 2 } }
  local low = rules:addSource(owner, {
    name = 'low',
    precedence = 10,
    resolve = function()
      return {
        width = function()
          error 'overwritten named evaluator called'
        end,
        chrome = function()
          return false
        end,
        callback = literal,
        payload = payload,
        evaluate = {
          dynamic = function()
            error 'overwritten extension evaluator called'
          end,
          kept = function(_, key)
            return key
          end,
        },
      }
    end,
  })
  local high = rules:addSource(owner, {
    name = 'high',
    precedence = 20,
    resolve = function()
      return {
        width = function(source, key)
          expect.equal(key, 'width', 'the key an evaluator receives')
          return source.width / 400
        end,
        dynamic = false,
      }
    end,
  })
  local resolved = rules:resolve(window)
  expect.equal(resolved.width, 2, 'the winning named evaluator')
  expect.equal(resolved.chrome, false, 'a named evaluator no source overrides')
  expect.equal(resolved.dynamic, false, 'a literal over an extension evaluator')
  expect.equal(resolved.kept, 'kept', 'an extension evaluator')
  expect.equal(resolved.callback, literal, 'a function under an unnamed key is a literal')
  expect.equal(resolved.payload, payload, 'a table is passed through')
  expect.equal(resolved.evaluate, nil, 'evaluate is not itself a property')
  low:dispose()
  high:dispose()
  session:close()
end)

test('a source name is registered once, and a disposed name is free again', function()
  local session, rules, owner, window = start()
  local first = rules:addSource(owner, {
    name = 'same',
    precedence = 100,
    resolve = function()
      return { width = 2 }
    end,
  })
  expect.raises(function()
    rules:addSource(owner, {
      name = 'same',
      precedence = 100,
      resolve = function()
        return nil
      end,
    })
  end, nil, 'a duplicate source name')
  expect.equal(#testing.ruleSources(rules), 1, 'a duplicate does not replace the registration')
  expect.equal(rules:resolve(window).width, 2, 'the first registration still resolves')
  first:dispose()
  first:dispose()
  local replacement = rules:addSource(owner, {
    name = 'same',
    precedence = 100,
    resolve = function()
      return { width = 3 }
    end,
  })
  expect.equal(#testing.ruleSources(rules), 1, 'the sources after the replacement')
  expect.equal(rules:resolve(window).width, 3, 'the replacement resolves')
  replacement:dispose()
  expect.equal(#testing.ruleSources(rules), 0, 'the sources after disposal')
  session:close()
end)

return test
