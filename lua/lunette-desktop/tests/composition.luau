-- Composition preserves default entry order, checks patches during load, and supports provider replacement and plugin insertion.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local laserModule = require '@lunette-plugins/laser'
local laserContract = require '@lunette-contracts/laser'
local frameContract = require '@lunette-contracts/frame'

local test = testing.suite()

local DEFAULT_IDS = table.concat({
  'frame',
  'theme',
  'surfaces',
  'panels',
  'drops',
  'focus',
  'bindings',
  'interaction',
  'laser',
  'keyboard',
  'ui',
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
  'desktop/render',
  'desktop/hint',
  'desktop/decorations',
  'desktop/pointing',
  'desktop/input',
  'desktop/keyboard',
  'desktop/menu',
  'desktop/actions',
  'desktop/errors',
  'desktop/workspace',
  'desktop/monitors',
  'desktop/rules',
  'desktop/pose-memory',
  'desktop/persistence',
  'desktop/arrange',
  'desktop/adoption',
  'desktop/pacing',
  'desktop/scale',
  'desktop/manager',
}, ' ')

local function ids(entries)
  local result = {}
  for index, entry in ipairs(entries) do
    result[index] = entry.id
  end
  return table.concat(result, ' ')
end

test('the default entries are listed in order, frozen, and each is configured by its id', function()
  local entries = desktop.entries()
  expect.equal(ids(entries), DEFAULT_IDS, 'the default entries')
  expect.equal(ids(desktop.compose()), DEFAULT_IDS, 'a composition without patches')
  expect.truthy(table.isfrozen(entries) and table.isfrozen(entries[1]), 'the default entries are frozen')
  for _, entry in ipairs(entries) do
    local patch = desktop.configureEntry(entry.id, entry.definition or entry.factory) {}
    expect.equal(patch.id, entry.id, 'the configure patch of ' .. entry.id)
  end
end)

test('run checks the composition as the configuration loads, before it binds the callbacks', function()
  local load = lovr.load
  expect.raises(function()
    desktop.run { patches = { { id = 'nope', disabled = true } } }
  end, 'a patch names nope')
  expect.equal(lovr.load, load, 'a malformed composition binds nothing')
  expect.raises(function()
    desktop.compose({ patch = {} } :: any)
  end, 'the options: unknown field patch')
end)

test('a provider built and wrapped by a patch replaces the built-in, and an inserted plugin draws', function()
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
    init = function(context)
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
      { id = 'laser', definition = countingLaser, config = { style = { length = 2.5 } } },
      { insert = { id = 'overlay', definition = overlay } },
    },
  })
  local events = session.native.events
  expect.equal(session.instances.laser:state(), 'active', 'the replacement laser')
  expect.equal(attached, 1, 'desktop/pointing attaches through the wrapper')
  session:update()
  session:draw()
  expect.equal(drawn, 1, 'the inserted plugin draws')
  -- The left hand is held aside, so its beam points at nothing and is drawn at full length.
  local ends = {}
  for _, call in ipairs(events.draw) do
    if call[1] == 'line' then
      ends[#ends + 1] = call[7]
    end
  end
  table.sort(ends)
  expect.near(ends[1], -2.5, 1e-9, 'the built laser draws at the configured length')
  expect.equal(session:quit(), false, 'quit does not veto')
  session:close()
end)

return test
