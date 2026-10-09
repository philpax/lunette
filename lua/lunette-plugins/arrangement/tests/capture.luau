-- Captures live panels and answers saved properties for windows.
local testing = require '@testing'
local expect = testing.expect
local capture = require '@lunette-plugins/arrangement/capture'
local slots = require '@lunette-plugins/arrangement/slots'
local fixture = require './support/fixture'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()
local TOLERANCE = 1e-5

local function entry(overrides)
  local value = {
    kind = 'window',
    key = 'terminal',
    slot = 1,
    pose = '1 0 0 0 0 1 0 0 0 0 1 0 1 1.5 -2 1',
    width = 1.2,
    height = 0.7,
    tags = { 'main' },
  }
  for key, replacement in pairs(overrides or {}) do
    value[key] = replacement
  end
  return value
end

-- Captures with fresh slots, as a binding's save does.
local function captured(panels, tags)
  return capture.capture(slots.new(), panels, tags).entries
end

local function window(appId, id)
  return { appId = appId, id = id or 1, dead = false, width = 800, height = 600, opaque = false }
end
local function monitor(id)
  return { id = id, dead = false, width = 1920, height = 1080 }
end

test(
  'capture keys windows on identity and ordered slots, monitors on identity, and records pose, size, and tags',
  function()
    fixture.run({}, function(env)
      local context, panels, tags = env.context, env.panels, env.tags
      local first = panels:fromWindow(context, window('terminal', 1), {
        pose = lovr.math.newMat4():translate(2, 3, -4),
        width = 1.6,
        height = 0.9,
      })
      tags:hold(context, { name = 'main' }):add(context, first)
      tags:hold(context, { name = 'side' }):add(context, first)
      panels:fromWindow(context, window('terminal', 2))
      panels:fromWindow(context, window('browser', 3))
      panels:fromMonitor(context, monitor 'fixture.monitor')
      local entries = captured(panels, tags)
      expect.equal(#entries, 4, 'the entries')
      expect.equal(entries[1].key, 'terminal', 'the first key')
      expect.equal(entries[1].slot, 1, 'the first slot')
      expect.equal(entries[1].pose, vocabulary.encodePose(first.pose), 'the pose')
      expect.near(entries[1].width, 1.6, TOLERANCE, 'the width')
      expect.near(entries[1].height, 0.9, TOLERANCE, 'the height')
      expect.equal(table.concat(entries[1].tags, ','), 'main,side', 'the tags')
      expect.equal(entries[2].slot, 2, 'the second slot')
      expect.equal(entries[3].key, 'browser', 'the third key')
      expect.equal(entries[3].slot, 1, 'the third slot')
      expect.equal(entries[4].kind, 'monitor', 'the monitor kind')
      expect.equal(entries[4].key, 'fixture.monitor', 'the monitor identity')
    end)
  end
)

test('panels with no stable identity, destroyed panels, and dead sources are not captured', function()
  local native = testing.native()
  fixture.run({ native = native }, function(env)
    local context, panels = env.context, env.panels
    panels:fromWindow(context, window(nil))
    panels:fromMonitor(context, monitor(8))
    expect.equal(#captured(panels, env.tags), 0, 'the unidentified entries')
    expect.equal(#native.events.logs, 2, 'the reports')
    expect.truthy(native.events.logs[1][1]:find('no identity', 1, true), 'the report')
    panels:fromWindow(context, window 'terminal'):destroy(context)
    local source = window('browser', 2)
    panels:fromWindow(context, source)
    source.dead = true
    expect.equal(#captured(panels, env.tags), 0, 'the entries')
  end)
end)

test('source answers the slot a window holds, and a dead window frees its slot', function()
  local held = slots.new()
  local available = capture.slotsFor { entries = { entry { width = 1 }, entry { slot = 2, width = 2 } } }
  local function resolve(window)
    return capture.answer(available, held, window)
  end
  local first, second = window('terminal', 1), window('terminal', 2)
  expect.near(resolve(first).width, 1, TOLERANCE, 'the first free slot')
  expect.near(resolve(second).width, 1, TOLERANCE, 'resolving takes no slot')
  held:hold(first)
  expect.near(resolve(first).width, 1, TOLERANCE, 'the held slot')
  expect.near(resolve(second).width, 2, TOLERANCE, 'the next free slot')
  held:hold(second)
  expect.falsy(resolve(window('terminal', 3)), 'the exhausted slots')
  first.dead = true
  expect.near(resolve(window('terminal', 4)).width, 1, TOLERANCE, 'a dead window frees its slot')
end)

return test
