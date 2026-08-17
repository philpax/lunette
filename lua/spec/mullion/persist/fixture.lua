-- The fakes the two `mullion.persist` spec files share.
--
-- `mullion.persist` has two halves — the arrangement panels are in, and the file
-- on disk — and a spec file for each. Both build the same panels, the same
-- entries, and the same in-memory filesystem, so those live here rather than
-- being written twice and drifting.
--
-- `spec.mullion.panel.fixture` is required through this, so that the
-- `mullion.panel` these reach is the one holding the fake `lunette`.
--
-- Not a spec file: the runner collects `*_spec.lua` and this is not one, so it
-- runs no cases of its own.

local panels = require '@spec/mullion/panel/fixture'

local persist = require '@mullion/persist'
local pose = require '@mullion/pose'
local rules = require '@mullion/rules'
local tag = require '@mullion/tag'

local fixture = {}

-- How close two metre quantities have to be to count as equal. Every number a
-- restore produces went through a matrix and a decimal rendering, so an exact
-- comparison would be asserting the formatting.
fixture.TOLERANCE = 1e-5

-- What `persist.report` was told, so that a case can assert an entry was
-- reported rather than let it print into the run's output.
fixture.reported = {}

-- What `mullion.rules` reported, kept apart from `mullion.persist`'s own reports
-- so that a case counting these is not counting that module's. A saved entry
-- names the tags it was on, and placing a window through the rules recreates
-- them, which that module says out loud.
fixture.ruleReports = {}

-- Discards everything a previous case left behind, including the memory of a
-- load that was declined.
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

-- A window source the rules can place, which is not a panel: `rules.place`
-- makes that itself.
function fixture.newWindow(appId, id)
  local window = panels.newWindow(800, 600)
  window.appId, window.id = appId, id or 1
  return window
end

-- A filesystem that holds one file in memory, so that the cases about an absent
-- or unwritable file do not depend on the state of a real directory.
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

-- An entry as this version writes them, with whatever a case wants changed.
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

-- A file's text at a version this mullion cannot read.
function fixture.fromTheFutureText()
  return 'return { version = ' .. (persist.CURRENT_VERSION + 1) .. ', entries = {}, curvature = 0.3 }'
end

return fixture
