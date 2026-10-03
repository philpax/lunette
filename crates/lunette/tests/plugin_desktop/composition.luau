-- The desktop composition: its default entries, every kind of patch, every
-- malformed patch, and a provider built, wrapped, and published through a
-- patch.
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local laserModule = require '@lunette-plugins/laser'
local laserContract = require '@lunette-contracts/laser'
local frameContract = require '@lunette-contracts/frame'
local graph = require 'fixture/graph'

local function ids(entries)
  local result = {}
  for index, entry in ipairs(entries) do
    result[index] = entry.id
  end
  return table.concat(result, ' ')
end

local function raises(expected, run)
  local ok, message = pcall(run)
  assert(not ok, 'expected an error naming ' .. expected)
  assert(tostring(message):find(expected, 1, true), 'expected ' .. expected .. ', got ' .. tostring(message))
end

-- The beam end of the left hand, which the fixture holds aside so it points
-- at nothing and is drawn at full length.
local function idleBeamEnd()
  local ends = {}
  for _, call in ipairs(events.draw) do
    if call[1] == 'line' then
      ends[#ends + 1] = call[7]
    end
  end
  table.sort(ends)
  return ends[1]
end

local DEFAULT_IDS = table.concat({
  'frame',
  'surfaces',
  'panels',
  'drops',
  'focus',
  'bindings',
  'interaction',
  'laser',
  'keyboard',
  'tags',
  'rules',
  'placement',
  'adoption',
  'layouts',
  'layout/arc',
  'errors',
  'pacing',
  'scale',
  'desktop/render',
  'desktop/hint',
  'desktop/decorations',
  'desktop/pointing',
  'desktop/input',
  'desktop/bindings',
  'desktop/keyboard',
  'desktop/errors',
  'desktop/workspace',
  'desktop/monitors',
  'desktop/rules',
  'desktop/pose-memory',
  'desktop/persistence',
  'desktop/arrange',
  'desktop/adoption',
  'desktop/demo-terminal',
  'desktop/pacing',
  'desktop/scale',
}, ' ')

-- The default list is inspectable and read-only.
local entries = desktop.entries()
assert(ids(entries) == DEFAULT_IDS, ids(entries))
assert(table.isfrozen(entries) and table.isfrozen(entries[1]), 'the default entries are frozen')
assert(not pcall(function()
  entries[1] = entries[2]
end))
for _, entry in ipairs(entries) do
  local factory = entry.id == 'desktop/persistence' or entry.id == 'desktop/arrange'
  assert((entry.factory ~= nil) == factory and (entry.definition == nil) == factory, entry.id)
end
assert(ids(desktop.compose()) == DEFAULT_IDS and ids(desktop.compose { patches = {} }) == DEFAULT_IDS)

-- Disabling removes the entry; nothing else moves.
local disabled = desktop.compose {
  patches = { { id = 'keyboard', disabled = true }, { id = 'desktop/keyboard', disabled = true } },
}
assert(not ids(disabled):find(' keyboard ', 1, true) and not ids(disabled):find('desktop/keyboard', 1, true))
assert(#disabled == #entries - 2)

-- Configuration merges: a record merges key by key, and anything else,
-- lists included, replaces the value it lands on.
local custom = {
  { id = 'laser', definition = laserModule.definition, config = { style = { length = 1, color = { 0, 0, 1, 1 } } } },
}
local merged = desktop.compose { entries = custom, patches = { { id = 'laser', config = { style = { length = 2 } } } } }
assert(merged[1].config.style.length == 2 and merged[1].config.style.color[3] == 1, 'a record merges')
local replaced =
  desktop.compose { entries = custom, patches = { { id = 'laser', config = { style = { color = { 1 } } } } } }
assert(#replaced[1].config.style.color == 1 and replaced[1].config.style.length == 1, 'a list replaces')
assert(custom[1].config.style.length == 1, 'composing leaves its inputs as they were')
assert(table.isfrozen(merged[1].config.style), 'a composed configuration is frozen')

-- A typed patch is the plain patch for its id, and each names a shipped entry.
local typed = desktop.configure.laser { style = { length = 2 } }
assert(typed.id == 'laser' and typed.config.style.length == 2, 'a typed patch names its entry and carries its options')
local typedMerge = desktop.compose { entries = custom, patches = { typed } }
assert(typedMerge[1].config.style.length == 2 and typedMerge[1].config.style.color[3] == 1, 'a typed patch merges')
local shipped = {}
for _, entry in ipairs(desktop.entries()) do
  shipped[entry.id] = true
end
local typedCount = 0
for id, make in desktop.configure do
  assert(shipped[id], 'configure names ' .. id .. ', which is not a shipped entry')
  assert(make({}).id == id, 'configure.' .. id .. ' patches ' .. id)
  typedCount += 1
end
assert(typedCount == 25, 'every shipped entry with options has a typed patch: ' .. typedCount)
assert(table.isfrozen(desktop.configure), 'the typed patches are frozen')

-- Malformed compositions raise before anything is defined or enabled, and
-- each error names the id.
local hud = plugin.define { name = 'hud', init = function() end }
raises('a patch names nope, which is not an entry', function()
  desktop.compose { patches = { { id = 'nope', disabled = true } } }
end)
raises('two patches name laser', function()
  desktop.compose { patches = { { id = 'laser', disabled = true }, { id = 'laser', config = {} } } }
end)
raises('two entries have the id hud', function()
  desktop.compose { entries = { { id = 'hud', definition = hud }, { id = 'hud', definition = hud } } }
end)
raises('the insert of laser names an entry that already exists', function()
  desktop.compose { patches = { { insert = { id = 'laser', definition = hud } } } }
end)
raises('patch 1: unknown field disable', function()
  desktop.compose { patches = { { id = 'laser', disable = true } } }
end)
raises('entry hud: unknown field configuration', function()
  desktop.compose { patches = { { insert = { id = 'hud', definition = hud, configuration = {} } } } }
end)
raises('the options: unknown field patch', function()
  desktop.compose { patch = {} }
end)
raises('the patch for laser disables the entry and also changes it', function()
  desktop.compose { patches = { { id = 'laser', disabled = true, config = {} } } }
end)
raises('the patch for laser gives both a definition and a factory', function()
  desktop.compose {
    patches = {
      {
        id = 'laser',
        definition = hud,
        factory = function()
          return hud
        end,
      },
    },
  }
end)
raises('the patch for laser changes nothing', function()
  desktop.compose { patches = { { id = 'laser' } } }
end)
raises('the patch for laser: disabled is true or absent, not false', function()
  desktop.compose { patches = { { id = 'laser', disabled = false } } }
end)
raises('patch 1 inserts an entry and also gives id', function()
  desktop.compose { patches = { { id = 'laser', insert = { id = 'hud', definition = hud } } } }
end)
raises('entry hud gives neither a definition nor a factory', function()
  desktop.compose { patches = { { insert = { id = 'hud' } } } }
end)
raises('the patch for laser: config is a table of options, not a number', function()
  desktop.compose { patches = { { id = 'laser', config = 3 } } }
end)
-- An insert goes at the end, or just before or after the entry it names.
local before =
  desktop.compose { patches = { { insert = { id = 'hud', definition = hud }, before = 'desktop/workspace' } } }
local beforeIds = ids(before)
assert(beforeIds:find('desktop/errors hud desktop/workspace', 1, true), beforeIds)
local after = desktop.compose { patches = { { insert = { id = 'hud', definition = hud }, after = 'frame' } } }
assert(ids(after):find '^frame hud surfaces', ids(after))
local chained = desktop.compose {
  patches = {
    { insert = { id = 'hud', definition = hud }, after = 'frame' },
    { insert = { id = 'hud-2', definition = hud }, after = 'hud' },
  },
}
assert(ids(chained):find '^frame hud hud%-2 surfaces', 'an insert can name an entry inserted before it')
raises('the insert of hud gives both before and after', function()
  desktop.compose { patches = { { insert = { id = 'hud', definition = hud }, before = 'frame', after = 'frame' } } }
end)
raises('the insert of hud goes before nope, which is not an entry', function()
  desktop.compose { patches = { { insert = { id = 'hud', definition = hud }, before = 'nope' } } }
end)
raises('the insert of hud: after is an entry id, not a number', function()
  desktop.compose { patches = { { insert = { id = 'hud', definition = hud }, after = 3 } } }
end)
raises('the patch for laser gives before or after', function()
  desktop.compose { patches = { { id = 'laser', disabled = true, before = 'frame' } } }
end)
raises('the patch list is a list, and position 2 is empty', function()
  desktop.compose { patches = { { id = 'laser', disabled = true }, nil, { id = 'tags', disabled = true } } }
end)

-- run checks the composition as the configuration loads, before it binds
-- LÖVR's callbacks.
local load = lovr.load
raises('a patch names nope', function()
  desktop.run { patches = { { id = 'nope', disabled = true } } }
end)
assert(lovr.load == load, 'a malformed composition binds nothing')

-- A factory is called once for each start and never by compose.
local made = 0
local factoryEntries = {
  {
    id = 'counted',
    factory = function()
      made += 1
      return hud
    end,
  },
}
desktop.compose { entries = factoryEntries }
assert(made == 0)
local first = plugin.start(factoryEntries)
local second = plugin.start(factoryEntries)
assert(made == 2 and first.instances.counted:state() == 'active')
first.runtime:close()
second.runtime:close()

-- A configuration a plugin does not take fails that plugin's activation and
-- names the plugin and the option; the rest of the desktop starts.
local rejected = plugin.start(desktop.compose { patches = { { id = 'desktop/errors', config = { colour = 'red' } } } })
assert(rejected.instances['desktop/errors']:state() == 'failed')
assert(
  tostring(rejected.instances['desktop/errors']:diagnostic()):find(
    'plugin desktop/errors: unknown option colour',
    1,
    true
  )
)
assert(rejected.instances['desktop/render']:state() == 'active')
rejected.runtime:close()

-- A provider built, wrapped, and published by a user definition replaces the
-- built-in through a patch, with the patch's configuration, and an inserted
-- plugin joins the frame.
local attached, drawn = 0, 0
local countingLaser = plugin.define {
  name = 'counting-laser',
  requires = laserModule.requires,
  provides = { laser = laserContract.capability },
  init = function(context, config, publish)
    local inner = laserModule.build(context, config)
    publish:provide(
      laserContract.capability,
      setmetatable({
        attach = function(_self, owner, options)
          attached += 1
          return inner:attach(owner, options)
        end,
      }, { __index = inner })
    )
  end,
}
local overlay = plugin.define {
  name = 'overlay',
  requires = { frame = frameContract.capability },
  init = function(context, config)
    plugin.options { name = 'overlay', defaults = { label = 'none' }, config = config }
    context:require(frameContract.capability):onDraw(context, {
      phase = 'overlay',
      run = function()
        drawn += 1
      end,
    })
  end,
}
local running = graph {
  patches = {
    { id = 'laser', definition = countingLaser, config = { style = { length = 2.5 } } },
    { insert = { id = 'overlay', definition = overlay, config = { label = 'hud' } } },
  },
}
assert(running.instances.laser:state() == 'active', tostring(running.instances.laser:diagnostic()))
assert(running.instances.overlay:state() == 'active', tostring(running.instances.overlay:diagnostic()))
assert(attached == 1, 'desktop/pointing attaches through the wrapper')
events.draw = {}
lovr.update(0.016)
lovr.draw(events.pass)
assert(drawn == 1, 'the inserted plugin draws')
assert(idleBeamEnd() == -2.5, 'the built laser uses the configured length: ' .. tostring(idleBeamEnd()))
assert(lovr.quit() == false)
