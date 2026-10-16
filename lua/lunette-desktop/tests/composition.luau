-- Composition configures entries by id, checks options during load, and supports provider replacement and plugin insertion.
local testing = require '@testing'
local vrUi = require '@testing/vr-ui'
local builtinEntries = require '@testing/builtin-entries'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local desktop = require '@lunette-desktop'
local settings = require '@lunette-desktop/settings'
local compose = require '@lunette-plugin/compose'
local laserModule = require '@lunette-plugins/input/laser'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

test('settings cover entries with options and shipped empty schemas', function()
  local expected = {
    'frame',
    'theme',
    'themes',
    'theme/standard',
    'theme/arcade',
    'surfaces',
    'panels',
    'drops',
    'focus',
    'bindings',
    'interaction',
    'laser',
    'keyboard',
    'ui-host',
    'ui-standard',
    'notifications',
    'accessibility',
    'menu',
    'desktop/theme',
    'tags',
    'rules',
    'placement',
    'adoption',
    'layouts',
    'layout/arc',
    'errors',
    'pacing',
    'scale',
    'audio',
    'audio-analysis',
    'desktop/render',
    'desktop/hint',
    'desktop/decorations',
    'desktop/pointing',
    'desktop/input',
    'desktop/keyboard',
    'desktop/menu',
    'desktop/actions',
    'desktop/errors',
    'desktop/workspaces',
    'desktop/monitors',
    'desktop/rules',
    'desktop/persistence',
    'desktop/arrange',
    'desktop/adoption',
    'desktop/pacing',
    'desktop/scale',
    'desktop/backdrop',
    'desktop/manager',
    'desktop/accessibility',
  }
  local entries = desktop.compose()
  expect.equal(#entries, #expected, 'the shipped entry count')
  local fields = settings.schema.inspect().fields
  local factories = { ['desktop/theme'] = true, ['desktop/persistence'] = true, ['desktop/arrange'] = true }
  for index, entry in ipairs(entries) do
    expect.equal(entry.id, expected[index], 'the shipped entry at position ' .. index)
    expect.equal(builtinEntries[entry.id], entry.definition, 'the registered definition of ' .. entry.id)
    local resolved = compose.resolveEntry(entry)
    expect.equal(resolved.definition.name, entry.id, 'the definition name of ' .. entry.id)
    expect.equal(type(entry.definition) == 'function', factories[entry.id] == true, 'the factory of ' .. entry.id)
    if factories[entry.id] then
      local fresh = compose.resolveEntry { id = entry.id, definition = builtinEntries[entry.id] }
      expect.falsy(rawequal(fresh.definition, resolved.definition), 'a fresh factory definition of ' .. entry.id)
    end
    local node = resolved.definition.schema
    while node and (node.kind == 'default' or node.kind == 'refine') do
      node = node.child
    end
    local hasOptions = node and node.fields and next(node.fields) ~= nil
    local hasSetting = hasOptions == true or entry.id == 'audio' or entry.id == 'audio-analysis'
    expect.equal(fields[entry.id] ~= nil, hasSetting, 'the setting of ' .. entry.id)
  end
  local registered = 0
  for _ in builtinEntries do
    registered += 1
  end
  expect.equal(registered, #expected, 'the registered entry count')
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
  expect.raises(function()
    testing.start { 'environment/backdrop' }
  end, 'testing session: unknown built%-in entry id environment/backdrop')
  local builtinSession = testing.boot { 'frame', 'theme', 'surfaces', 'panels', 'desktop/render' }
  expect.equal(builtinSession.instances['desktop/render']:state(), 'active', 'a string id with a different module path')
  builtinSession:update()
  builtinSession:draw()
  builtinSession:close()

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
