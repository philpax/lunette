local testing = require '@testing'
local expect = testing.expect
local config = require '@lunette-plugins/desktop/rules/config'
local definition = require '@lunette-plugins/desktop/rules'
local policy = require '@lunette-plugins/rules/policy'

local test = testing.suite()

local invalidRules = {
  { rule = { match = { where = 42 } }, message = 'match field where' },
  { rule = { match = { width = 'wide' } }, message = 'match field width' },
  { rule = { match = { dead = 1 } }, message = 'match field dead' },
  { rule = { match = { contentType = 'audio' } }, message = 'match field contentType' },
  { rule = { match = { unknown = true } }, message = 'unsupported match field unknown' },
  { rule = { properties = { width = 'wide' } }, message = 'property width' },
  { rule = { properties = { chrome = 1 } }, message = 'property chrome' },
  { rule = { properties = { pose = {} } }, message = 'property pose' },
  { rule = { properties = { tags = { 42 } } }, message = 'property tags' },
  { rule = { properties = { tags = { main = true } } }, message = 'property tags' },
  { rule = { properties = { evaluate = false } }, message = 'evaluate' },
  { rule = { properties = { evaluate = { extension = false } } }, message = 'extension evaluator' },
  { rule = { properties = { evaluate = { [1] = function() end } } }, message = 'evaluator key' },
  { rule = { properties = { evaluate = { width = function() end } } }, message = 'reserved property width' },
  {
    rule = { properties = { extension = {}, evaluate = { extension = function() end } } },
    message = 'both a literal and an evaluator',
  },
}

for _, case in invalidRules do
  test('parse and resolve reject ' .. case.message, function()
    local input = { rules = { case.rule } }
    expect.raises(function()
      config.schema.parse(input)
    end, case.message, 'schema parse')
    expect.raises(function()
      definition.resolve(input)
    end, case.message, 'definition resolution')
  end)
end

test('custom rule values are revalidated after caller mutation between resolutions', function()
  for _, change in
    {
      function(rule)
        rule.match.where = 42
        return 'match field where'
      end,
      function(rule)
        rule.properties.width = 'wide'
        return 'property width'
      end,
      function(rule)
        rule.properties.evaluate.extension = false
        return 'extension evaluator'
      end,
    }
  do
    local rule = {
      match = {
        where = function()
          return true
        end,
      },
      properties = { width = 2, evaluate = {
        extension = function()
          return 1
        end,
      } },
    }
    local input = { rules = { rule } }
    local settings = definition.resolve(input)
    expect.equal(settings.rules[1], rule, 'custom rule identity')
    local message = change(rule)
    expect.raises(function()
      definition.resolve(input)
    end, message, 'input re-resolution')
    expect.raises(function()
      definition.resolve(settings)
    end, message, 'settings re-resolution')
  end
end)

test('valid rule payloads retain callbacks, matrices, extension tables, and custom table identity', function()
  local predicate = function()
    return true
  end
  local evaluator = function()
    return 2
  end
  local callback = function() end
  local payload = setmetatable({ nested = { 1, 2 } }, {
    __index = function()
      error 'extension payload indexed during validation'
    end,
    __iter = function()
      error 'extension payload iterated during validation'
    end,
  })
  local pose = lovr.math.newMat4()
  local match = { width = predicate, where = predicate }
  local properties = {
    pose = pose,
    width = evaluator,
    tags = { 'main' },
    payload = payload,
    callback = callback,
    evaluate = { extension = evaluator },
  }
  local rule = { match = match, properties = properties }
  local parsed = config.schema.parse { rules = { rule } }
  local resolved = definition.resolve { rules = { rule } }
  for _, settings in { parsed, resolved, definition.resolve(resolved) } do
    expect.equal(settings.rules[1], rule, 'rule identity')
    expect.equal(settings.rules[1].match, match, 'match identity')
    expect.equal(settings.rules[1].properties, properties, 'properties identity')
    expect.equal(settings.rules[1].match.where, predicate, 'predicate identity')
    expect.equal(settings.rules[1].properties.pose, pose, 'matrix identity')
    expect.equal(settings.rules[1].properties.width, evaluator, 'named evaluator identity')
    expect.equal(settings.rules[1].properties.evaluate.extension, evaluator, 'extension evaluator identity')
    expect.equal(settings.rules[1].properties.callback, callback, 'literal callback identity')
    expect.equal(settings.rules[1].properties.payload, payload, 'extension table identity')
  end
  expect.falsy(table.isfrozen(properties), 'custom properties stay caller-owned')
  local collected = policy.layer({}, properties)
  expect.equal(collected.pose, pose, 'layer preserves matrix identity')
  expect.equal(collected.payload, payload, 'layer preserves extension identity')
end)

test('provider list registration uses the same validation before any window is processed', function()
  local rules = require '@lunette-contracts/rules'
  local session = testing.start { 'rules' }
  local observed = session:observe(rules.capability)
  for _, case in invalidRules do
    expect.raises(function()
      observed.service:setRules(observed.context, { rules = { case.rule } })
    end, case.message, 'setRules validation')
  end
  expect.equal(#testing.ruleSources(observed.service), 0, 'invalid rule sets register no source')
  session:close()
end)

for _, case in
  {
    {
      name = 'match',
      inherited = { where = 42 },
      wrap = function(container)
        return { match = container }
      end,
    },
    {
      name = 'properties',
      inherited = { width = 'wide' },
      wrap = function(container)
        return { properties = container }
      end,
    },
    {
      name = 'evaluate map',
      inherited = { extension = false },
      wrap = function(container)
        return { properties = { evaluate = container } }
      end,
    },
    {
      name = 'tags list',
      inherited = { [1] = 42 },
      wrap = function(container)
        return { properties = { tags = container } }
      end,
    },
  }
do
  for _, behavior in { 'inherited fields', 'iteration callback' } do
    test(case.name .. ' rejects a metatable with ' .. behavior .. ' at every rule entry point', function()
      local rules = require '@lunette-contracts/rules'
      local session = testing.start { 'rules' }
      local observed = session:observe(rules.capability)
      local metamethodCalls, callbackCalls = 0, 0
      local container = setmetatable(
        {},
        if behavior == 'inherited fields'
          then { __index = case.inherited }
          else {
            __iter = function()
              metamethodCalls += 1
              return next, {}, nil
            end,
            __index = function()
              metamethodCalls += 1
              return nil
            end,
          }
      )
      local rule = case.wrap(container)
      if case.name ~= 'match' then
        rule.match = {
          where = function()
            callbackCalls += 1
            return true
          end,
        }
      end
      local input = { rules = { rule } }
      for _, entry in
        {
          {
            name = 'schema parse',
            run = function()
              config.schema.parse(input)
            end,
          },
          {
            name = 'definition resolution',
            run = function()
              definition.resolve(input)
            end,
          },
          {
            name = 'setRules',
            run = function()
              observed.service:setRules(observed.context, input)
            end,
          },
        }
      do
        local ok, message = pcall(entry.run)
        expect.equal(metamethodCalls, 0, entry.name .. ' does not execute container metamethods')
        expect.equal(callbackCalls, 0, entry.name .. ' does not process a window')
        expect.falsy(ok, entry.name .. ' rejects the container metatable')
        expect.truthy(tostring(message):find('plain table', 1, true), tostring(message))
      end
      expect.equal(#testing.ruleSources(observed.service), 0, 'rejected containers register no source')
      session:close()
    end)
  end
end

return test
