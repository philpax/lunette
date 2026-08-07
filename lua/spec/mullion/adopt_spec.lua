-- Covers lua/mullion/adopt.lua.
--
-- The acceptance criterion is that a soft reload applies an edited layout
-- without disconnecting a client and without scrambling a hand-arranged
-- workspace, so the cases that matter most are the two halves of that: a panel
-- the user placed by hand comes back where they left it, and a window nobody
-- placed is placed by rule.
--
-- The reload itself is native and is exercised by `crates/lunette/tests/reload.rs`
-- against a real session. What is reproduced here is the shape a reload leaves
-- behind: the hooks have run, the modules' state is empty, the configuration has
-- installed its sources again, and the windows and the native property store are
-- exactly as they were — because a reload does not touch them.
--
-- The panel fixture is required first, so that the `mullion.panel` and the
-- `lunette` these reach through are the fakes. A real `lunette.windows()` would
-- want a compositor.

local expect = require 'spec.expect'
local fixture = require 'spec.mullion.panel.fixture'
local suite = require 'spec.suite'

local adopt = require 'mullion.adopt'
local interaction = require 'mullion.interaction'
local pose = require 'mullion.pose'
local rules = require 'mullion.rules'
local tag = require 'mullion.tag'

local spec = suite.new 'mullion.adopt'

local panel = fixture.panel
local TOLERANCE = fixture.TOLERANCE

-- Where a rule would put a terminal, and where the user dragged one instead.
local RULE_POSE = { 0, 1.5, -2 }
local HAND_POSE = { 1.1, 1.2, -0.8 }

local function reset()
  rules.teardown()
  tag.teardown()
  fixture.reset()
  rules.report = function() end
end

-- A window the fake `lunette.windows()` will answer with.
local function newWindow(appId)
  local window = fixture.newWindow(800, 600)
  window.appId = appId
  fixture.windows[#fixture.windows + 1] = window
  return window
end

-- What the configuration does at every start, whether it is the first or the
-- one a reload caused: it declares its rules and installs its sources.
local function configure()
  rules.setRules {
    {
      match = { appId = 'terminal' },
      properties = { pose = pose.encode(fixture.poseAt(RULE_POSE[1], RULE_POSE[2], RULE_POSE[3])) },
    },
  }
  adopt.install()
end

-- The reload, as far as this module can see one: every module's teardown hook
-- runs, so the panels and the sources go, and the configuration runs again.
-- Nothing touches the windows or the store, which is what a reload does not do.
local function reload()
  panel.teardown()
  rules.teardown()
  tag.teardown()
  configure()
end

local function positionOf(target)
  local x, y, z = target.pose:getPosition()
  return { x, y, z }
end

local function expectPosition(target, wanted, context)
  local actual = positionOf(target)
  for index = 1, 3 do
    expect.near(actual[index], wanted[index], TOLERANCE, context .. ' component ' .. index)
  end
end

spec('a hand-placed panel returns to its stored pose after a reload', function()
  reset()
  local window = newWindow 'terminal'
  configure()

  local placed = rules.place(window)
  expectPosition(placed, RULE_POSE, 'the rule should have placed it')
  -- The user drags it, and the drop writes the pose to the native store.
  placed:setPose(fixture.poseAt(HAND_POSE[1], HAND_POSE[2], HAND_POSE[3]))
  expect.truthy(interaction.storePose(placed), 'the drop should have stored the pose')

  reload()
  local adopted = adopt.windows()
  expect.equal(#adopted, 1, 'the windows to adopt')

  local again = rules.place(adopted[1])
  expectPosition(again, HAND_POSE, 'the stored pose should have won')
end)

spec('a window with no stored state is placed by rule', function()
  reset()
  local window = newWindow 'terminal'
  configure()

  local adopted = adopt.windows()
  expect.equal(#adopted, 1, 'the windows to adopt')

  local placed = rules.place(adopted[1])
  expectPosition(placed, RULE_POSE, 'the rule should have placed it')
end)

spec('a window that closed during the reload is not resurrected', function()
  reset()
  local staying = newWindow 'terminal'
  local going = newWindow 'browser'
  configure()
  rules.place(staying)
  rules.place(going)

  -- The client exits while the reload is running: the compositor drops it from
  -- the snapshot, so the next enumeration does not list it.
  going.dead = true
  fixture.windows = { staying }
  reload()

  local adopted = adopt.windows()
  expect.equal(#adopted, 1, 'the windows to adopt')
  expect.equal(adopted[1], staying, 'the window that is still there')
end)

spec('a window that opened during the reload is picked up', function()
  reset()
  local first = newWindow 'terminal'
  configure()
  rules.place(first)

  reload()
  -- The client that connected while the reload was running. The
  -- `lovr.lunwindowopened` for it went to the state that has gone, so the
  -- enumeration is the only way this configuration hears about it.
  local second = newWindow 'browser'

  local adopted = adopt.windows()
  expect.equal(#adopted, 2, 'the windows to adopt')
  expect.equal(adopted[1], first, 'the window that was already there')
  expect.equal(adopted[2], second, 'the window that arrived during the reload')
end)

spec('a window a panel is already showing is not adopted twice', function()
  reset()
  local window = newWindow 'terminal'
  configure()

  rules.place(window)

  expect.equal(#adopt.windows(), 0, 'the windows to adopt')
end)

spec('a panel is found from a second handle to the same window', function()
  reset()
  local window = newWindow 'terminal'
  configure()
  local placed = rules.place(window)

  -- What `lunette.windows()` hands back is a fresh handle every call, so the
  -- lookup cannot be on the table. A handle carrying the same identifier is the
  -- same window.
  local again = { id = window.id, dead = false }
  expect.equal(panel.forSource(again), placed, 'the panel over the window')
  expect.equal(panel.forSource { id = window.id + 1 }, nil, 'a different window')
  expect.equal(panel.forSource(nil), nil, 'no source at all')
end)

spec('a destroyed panel stops answering for its window', function()
  reset()
  local window = newWindow 'terminal'
  configure()
  rules.place(window):destroy()

  expect.equal(panel.forSource(window), nil, 'the panel over the window')
  expect.equal(#adopt.windows(), 1, 'the windows to adopt')
end)

spec('the store outranks the rules table and the saved arrangement', function()
  reset()
  configure()

  local names = {}
  for index, source in ipairs(rules.sources()) do
    names[index] = source.name
  end

  expect.equal(table.concat(names, ','), 'mullion.rules,mullion.adopt', 'the source order')
  expect.truthy(
    adopt.PRECEDENCE > require('mullion.persist').PRECEDENCE,
    'the live store should outrank the file the last session wrote'
  )
end)

spec('a configuration can put the rules above the store', function()
  reset()
  local window = newWindow 'terminal'
  rules.setRules {
    {
      match = { appId = 'terminal' },
      properties = { pose = pose.encode(fixture.poseAt(RULE_POSE[1], RULE_POSE[2], RULE_POSE[3])) },
    },
  }
  -- Below `mullion.rules.DEFAULT_PRECEDENCE`, which is the statement that the
  -- rules should beat what the user last dragged the window to.
  adopt.install(rules.DEFAULT_PRECEDENCE - 1)

  local placed = rules.place(window)
  placed:setPose(fixture.poseAt(HAND_POSE[1], HAND_POSE[2], HAND_POSE[3]))
  interaction.storePose(placed)
  placed:destroy()

  expectPosition(rules.place(window), RULE_POSE, 'the rule should have won')
end)

spec('a window with nothing stored answers nothing', function()
  reset()
  local window = newWindow 'terminal'

  expect.equal(adopt.properties(window), nil, 'the stored properties')

  window:setProperty(interaction.POSE_PROPERTY, pose.encode(fixture.poseAt(1, 2, 3)))
  local properties = adopt.properties(window)
  expect.truthy(properties ~= nil, 'the stored properties')
  expect.equal(properties.pose, window:getProperty(interaction.POSE_PROPERTY), 'the stored pose')
end)

spec('properties are asked of a window, not of a name', function()
  reset()

  expect.raises(function()
    adopt.properties 'terminal'
  end, 'mullion.adopt', 'a window that is a string')
end)

return spec
