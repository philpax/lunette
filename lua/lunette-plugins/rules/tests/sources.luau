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
  rules:setRules(owner, {
    name = 'matching',
    precedence = 100,
    rules = {
      {
        match = {
          appId = function(value)
            return value == 'fixture'
          end,
          title = 'Fixture',
        },
        properties = { width = 1 },
      },
      {
        match = {
          appId = 'fixture',
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
  expect.equal(resolved.chrome, nil, 'where refusing overrides a matching field')
  expect.raises(function()
    rules:setRules(owner, { rules = { { match = { typo = true } } } })
  end, 'unsupported match field typo', 'an unsupported match key')
  session:close()
end)

test('a higher precedence source wins a key, and only the winning evaluator is called', function()
  local session, rules, owner, window = start()
  local literal = function() end
  rules:addSource(owner, {
    name = 'low',
    precedence = 10,
    resolve = function()
      return {
        width = function()
          error 'overwritten evaluator called'
        end,
        chrome = false,
        callback = literal,
      }
    end,
  })
  rules:addSource(owner, {
    name = 'high',
    precedence = 20,
    resolve = function()
      return {
        width = function(source)
          return source.width / 400
        end,
      }
    end,
  })
  local resolved = rules:resolve(window)
  expect.equal(resolved.width, 2, 'the winning evaluator')
  expect.equal(resolved.chrome, false, 'a key no higher source sets')
  expect.equal(resolved.callback, literal, 'a function under an unnamed key is a literal')
  session:close()
end)

test('a source name is registered once, and a disposed name is free again', function()
  local session, rules, owner = start()
  local source = {
    name = 'same',
    precedence = 100,
    resolve = function()
      return nil
    end,
  }
  local first = rules:addSource(owner, source)
  expect.raises(function()
    rules:addSource(owner, source)
  end, nil, 'a duplicate source name')
  first:dispose()
  rules:addSource(owner, source)
  expect.equal(#testing.ruleSources(rules), 1, 'the sources after the replacement')
  session:close()
end)

return test
