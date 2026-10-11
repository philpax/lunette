-- Composition configures entries by id, checks options during load, and supports provider replacement and plugin insertion.
local testing = require '@testing'
local vrUi = require '@testing/vr-ui'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local settings = require '@lunette-desktop/settings'
local compose = require '@lunette-plugin/compose'
local laserModule = require '@lunette-plugins/laser'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

test('settings cover every default entry that takes options', function()
  local fields = settings.schema.inspect().fields
  for _, entry in ipairs(desktop.compose()) do
    local node = compose.resolveEntry(entry).definition.schema
    while node and (node.kind == 'default' or node.kind == 'refine') do
      node = node.child
    end
    local options = node and node.fields and next(node.fields) ~= nil
    expect.equal(fields[entry.id] ~= nil, options == true, 'the setting of ' .. entry.id)
  end
end)

test('malformed options raise as the configuration loads, before callbacks bind', function()
  local load = lovr.load
  for _, case in ipairs {
    { options = { patches = { { id = 'nope', disabled = true } } }, message = 'a patch names nope' },
    { options = { settings = { nope = {} } }, message = 'option nope is not a declared field' },
    {
      options = { settings = { ['desktop/keyboard'] = {} }, patches = { { id = 'desktop/keyboard', config = {} } } },
      message = 'two patches name desktop/keyboard',
    },
  } do
    expect.raises(function()
      desktop.run(case.options :: any)
    end, case.message)
    expect.equal(lovr.load, load, 'invalid options bind no callbacks')
  end
end)

test('a patch replaces a built-in definition, and an inserted plugin draws', function()
  local drawn = 0
  local replacement = laserModule.define { name = 'replacement-laser', style = { length = 2.5 } }
  local overlay = adapter.define {
    name = 'overlay',
    requires = { frameContract.capability },
    init = function(context: adapter.Context)
      context:require(frameContract.capability):onDraw(context, {
        phase = 'overlay',
        run = function()
          drawn += 1
        end,
      })
    end,
  }
  local session = testing.boot(desktop.compose {
    patches = {
      { id = 'laser', definition = replacement },
      { insert = { id = 'overlay', definition = overlay } },
    },
  })
  local events = session.native.events
  vrUi.hands(session.native)
  expect.equal(session.instances.laser:state(), 'active', 'the replacement laser')
  session:update()
  session:draw()
  expect.equal(drawn, 1, 'the inserted plugin draws')
  -- The left hand is held aside, so its beam points at nothing and is drawn at full length.
  local ends: { number } = {}
  for _, call in ipairs(events.draw) do
    if call[1] == 'line' then
      ends[#ends + 1] = call[7]
    end
  end
  table.sort(ends)
  expect.near(ends[1], -2.5, 1e-9, 'the replacement laser draws at its bound length')
  expect.equal(session:quit(), false, 'quit does not veto')
  session:close()
end)

return test
