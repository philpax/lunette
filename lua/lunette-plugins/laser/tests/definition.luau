local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local laserContract = require '@lunette-contracts/laser'
local laser = require '@lunette-plugins/laser'

local test = testing.suite()

local function start(extra)
  testing.native()
  local entries = { 'theme', 'drops', 'focus', 'interaction' }
  for _, entry in ipairs(extra) do
    entries[#entries + 1] = entry
  end
  return testing.start(entries)
end

test("define's options are new defaults, and a configuration merges over them", function()
  local long = laser.define { name = 'long-laser', style = { length = 3 } }
  expect.equal(long.name, 'long-laser', 'the defined name')
  expect.equal(laser.definition.name, 'laser', 'the built-in definition keeps its name')
  local session = start {
    { id = 'laser', definition = long, config = { style = { color = { 1, 0, 0, 1 } } } },
  }
  expect.equal(session.instances.laser:state(), 'active', tostring(session.instances.laser:diagnostic()))
  local style = session:observe(laserContract.capability).service.STYLE
  expect.equal(style.length, 3, 'the defined length')
  expect.equal(style.color[1], 1, 'the configured colour, red')
  expect.equal(style.color[2], 0, 'the configured colour, green')
  expect.equal(style.cursorRadius, 0.006, 'a default neither one names')
  session:close()
  expect.equal(laser.define({}).name, 'laser', 'define without a name keeps the default name')
end)

test('build rejects what a configuration rejects, and takes the defaults without one', function()
  local built = {}
  local session = start {
    {
      id = 'builder',
      definition = plugin.define {
        name = 'builder',
        requires = laser.requires,
        init = function(context)
          built.ok, built.message = pcall(laser.build, context, { style = { colour = {} } })
          built.service = laser.build(context)
        end,
      },
    },
  }
  expect.equal(session.instances.builder:state(), 'active', tostring(session.instances.builder:diagnostic()))
  expect.falsy(built.ok, 'build with an unknown option')
  expect.truthy(
    tostring(built.message):find('plugin laser: option style.colour is not a declared field', 1, true),
    tostring(built.message)
  )
  expect.equal(built.service.STYLE.length, 1.5, 'build without a configuration takes the defaults')
  session:close()
end)

test('define rejects an unknown option, a wrong type under the new name, and a name that is not a string', function()
  expect.raises(function()
    laser.define { bogus = 1 }
  end, 'plugin laser: option bogus is not a declared field', 'an unknown option')
  expect.raises(function()
    laser.define { name = 'short-laser', style = { length = 'short' } }
  end, 'plugin short%-laser: option style.length is a finite number, not a string', 'a wrong type')
  expect.raises(function()
    laser.define { name = 5 }
  end, 'define names a definition with a non%-empty string, not 5', 'a name that is not a string')
end)

return test
