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
    { 'frame', 'lunette/frame@2' },
    { 'theme', 'lunette/theme@1' },
    { 'themes', 'lunette/themes@1' },
    { 'theme/standard' },
    { 'theme/arcade' },
    { 'surfaces', 'lunette/surfaces@1' },
    { 'panels', 'lunette/panels@3' },
    { 'drops', 'lunette/drops@1' },
    { 'focus', 'lunette/focus@2' },
    { 'bindings', 'lunette/bindings@1' },
    { 'interaction', 'lunette/interaction@2' },
    { 'laser', 'lunette/laser@1' },
    { 'keyboard', 'lunette/keyboard@3' },
    { 'ui', 'lunette/ui@3' },
    { 'menu', 'lunette/menu@1' },
    { 'desktop/theme' },
    { 'tags', 'lunette/tags@1' },
    { 'rules', 'lunette/rules@1' },
    { 'placement', 'lunette/placement@1' },
    { 'adoption', 'lunette/adoption@1' },
    { 'layouts', 'lunette/layouts@1' },
    { 'layout/arc' },
    { 'errors', 'lunette/errors@1' },
    { 'pacing', 'lunette/pacing@1' },
    { 'scale', 'lunette/scale@1' },
    { 'audio', 'lunette/audio@1' },
    { 'audio-analysis', 'lunette/audio-analysis@2' },
    { 'desktop/render' },
    { 'desktop/hint' },
    { 'desktop/decorations' },
    { 'desktop/pointing' },
    { 'desktop/input' },
    { 'desktop/keyboard', 'lunette/keyboard-display@1' },
    { 'desktop/menu' },
    { 'desktop/actions' },
    { 'desktop/errors' },
    { 'desktop/workspaces' },
    { 'desktop/monitors' },
    { 'desktop/rules' },
    { 'desktop/persistence', 'lunette/arrangement@1' },
    { 'desktop/arrange' },
    { 'desktop/adoption' },
    { 'desktop/pacing' },
    { 'desktop/scale' },
    { 'desktop/backdrop' },
    { 'desktop/manager' },
  }
  local entries = desktop.compose()
  expect.equal(#entries, #expected, 'the shipped entry count')
  local fields = settings.schema.inspect().fields
  local known = {}
  local factories = { ['desktop/theme'] = true, ['desktop/persistence'] = true, ['desktop/arrange'] = true }
  for index, entry in ipairs(entries) do
    local wanted = expected[index]
    expect.equal(entry.id, wanted[1], 'the shipped entry at position ' .. index)
    known[entry.id] = true
    expect.equal(builtinEntries[entry.id], entry.definition, 'the registered definition of ' .. entry.id)
    local resolved = compose.resolveEntry(entry)
    expect.equal(resolved.definition.name, entry.id, 'the definition name of ' .. entry.id)
    expect.equal(#resolved.definition.provides, if wanted[2] then 1 else 0, 'the provider count of ' .. entry.id)
    if wanted[2] then
      expect.equal(resolved.definition.provides[1].contract, wanted[2], 'the capability of ' .. entry.id)
    end
    expect.equal(type(entry.definition) == 'function', factories[entry.id] == true, 'the factory of ' .. entry.id)
    if factories[entry.id] then
      local fresh = compose.resolveEntry { id = entry.id, definition = builtinEntries[entry.id] }
      expect.falsy(rawequal(fresh.definition, resolved.definition), 'a fresh factory definition of ' .. entry.id)
      expect.equal(fresh.definition.name, entry.id, 'the factory definition name of ' .. entry.id)
      expect.equal(
        fresh.definition.provides[1],
        resolved.definition.provides[1],
        'the factory capability of ' .. entry.id
      )
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
  for id in builtinEntries do
    expect.truthy(known[id], 'the registry contains only shipped ids: ' .. id)
    registered += 1
  end
  expect.equal(registered, #expected, 'the registered entry count')
  for id in fields do
    expect.truthy(known[id], 'the settings contain only shipped ids: ' .. id)
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
