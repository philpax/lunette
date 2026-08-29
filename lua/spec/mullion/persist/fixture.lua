-- The fakes the two `mullion.persist` spec files share.
--
-- `mullion.persist` has two halves, the arrangement of panels and the file on
-- disk, and a spec file for each. Both specs build the same panels, the same
-- entries, and the same in-memory filesystem. Defining each of them once
-- avoids two copies that drift apart.
--
-- The fixture requires `spec.mullion.panel.fixture`, which installs the fake
-- `lunette` and then loads `mullion.panel`. The `mullion.panel` the two
-- specs reach holds that fake.
--
-- The runner collects `*_spec.lua`, and the fixture's name does not match, so
-- the runner runs no cases from it.

local panels = require '@spec/mullion/panel/fixture'

local persist = require '@mullion/persist'
local pose = require '@mullion/pose'
local rules = require '@mullion/rules'
local tag = require '@mullion/tag'

local fixture = {}

-- Two metre quantities count as equal when they differ by at most this amount.
-- Every number a restore produces goes through a matrix and a decimal
-- rendering, so an exact comparison would assert the formatting.
fixture.TOLERANCE = 1e-5

-- The messages `persist.report` received. `reset` replaces `persist.report`
-- with a capture that appends each message to `fixture.reported`. A case
-- asserts against the list, and the messages do not print into the run's
-- output.
fixture.reported = {}

-- The messages `mullion.rules` reported, kept apart from `mullion.persist`'s
-- reports so a case counting these does not count the other module's.
-- A saved entry names the tags the window carries. Placing a window through
-- the rules recreates those tags, and `mullion.rules` reports the recreation.
fixture.ruleReports = {}

-- Discards everything a previous case left behind, including a declined load,
-- and reinstalls the report captures.
function fixture.reset()
  rules.teardown()
  tag.teardown()
  panels.reset()
  persist.teardown()

  fixture.reported = {}
  persist.report = function(message)
    fixture.reported[#fixture.reported + 1] = message
  end
  fixture.ruleReports = {}
  rules.report = function(message)
    fixture.ruleReports[#fixture.ruleReports + 1] = message
  end
end

-- A window panel over a source with the given application identifier.
function fixture.newWindowPanel(appId, options)
  local window = panels.newWindow(800, 600)
  window.appId = appId
  window.id = appId .. '-' .. tostring(options and options.id or 1)
  return panels.panel.fromWindow(window, options)
end

-- A monitor panel over a screen with the given saved identity.
function fixture.newMonitorPanel(id, options)
  local monitor = panels.newSource(1920, 1080)
  monitor.id = id
  return panels.panel.fromMonitor(monitor, options)
end

-- A window source the rules can place. The helper returns a source, and
-- `rules.place` creates the panel from it.
function fixture.newWindow(appId, id)
  local window = panels.newWindow(800, 600)
  window.appId, window.id = appId, id or 1
  return window
end

-- A filesystem holding one file in memory. The cases about an absent or
-- unwritable file do not depend on the state of a real directory.
function fixture.newFilesystem(text)
  local filesystem = { text = text, writes = 0, writable = true }

  function filesystem.getSaveDirectory()
    return '/a/save/directory'
  end

  function filesystem.read()
    return filesystem.text
  end

  function filesystem.write(_, contents)
    if not filesystem.writable then
      return false
    end
    filesystem.writes = filesystem.writes + 1
    filesystem.text = contents
    return true
  end

  return filesystem
end

-- An entry in the shape this version writes. A case overrides any field.
function fixture.newEntry(overrides)
  local entry = {
    kind = 'window',
    key = 'terminal',
    slot = 1,
    pose = pose.encode(lovr.math.newMat4():translate(1, 1.5, -2)),
    width = 1.2,
    height = 0.7,
    tags = { 'main' },
  }
  for key, value in pairs(overrides or {}) do
    entry[key] = value
  end
  return entry
end

-- A file's text at a version higher than `persist.CURRENT_VERSION`. This
-- mullion leaves such a file alone.
function fixture.fromTheFutureText()
  return 'return { version = ' .. (persist.CURRENT_VERSION + 1) .. ', entries = {}, curvature = 0.3 }'
end

return fixture
