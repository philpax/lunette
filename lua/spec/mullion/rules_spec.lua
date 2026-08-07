-- Covers lua/mullion/rules.lua.
--
-- The acceptance criterion this module carries is that a rule matching on
-- `appId` places a newly spawned window without further scripting, so the case
-- that matters most is the one that goes all the way to a panel at the pose the
-- rule named. The rest is matching and composition, both pure over synthetic
-- window tables.
--
-- The panel fixture is required before `mullion.rules` is, so that the
-- `mullion.panel` the module captures is the one holding the fake `lunette`. A
-- real `lunette.claimLayer` would want a layer pool with no headset behind it.

local expect = require 'spec.expect'
local fixture = require 'spec.mullion.panel.fixture'
local suite = require 'spec.suite'

local rules = require 'mullion.rules'
local tag = require 'mullion.tag'

local spec = suite.new 'mullion.rules'

local TOLERANCE = 1e-5

-- A window, as far as a rule is concerned.
local function newWindow(appId, title)
  local window = fixture.newWindow(800, 600)
  window.appId = appId
  window.title = title
  return window
end

-- What `rules.report` was told, so that a case can assert a rule was reported
-- rather than let it print into the run's output.
local reported = {}
local function captureReports()
  reported = {}
  rules.report = function(message)
    reported[#reported + 1] = message
  end
end

-- A fresh set of sources, tags, and panels for each case.
local function reset()
  rules.teardown()
  tag.teardown()
  fixture.reset()
  captureReports()
end

spec('a rule matching appId applies its properties', function()
  reset()
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { width = 1.25 } },
  }

  local properties = rules.resolve(newWindow 'terminal')
  expect.near(properties.width, 1.25, TOLERANCE, 'the width')
end)

spec('a rule that does not match applies nothing', function()
  reset()
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { width = 1.25 } },
  }

  local properties = rules.resolve(newWindow 'browser')
  expect.falsy(properties.width, 'the width')
end)

spec('two matching rules layer in order', function()
  reset()
  rules.setRules {
    { properties = { width = 1, height = 2 } },
    { match = { appId = 'terminal' }, properties = { width = 3 } },
  }

  local properties = rules.resolve(newWindow 'terminal')
  expect.near(properties.width, 3, TOLERANCE, 'the width the later rule set')
  expect.near(properties.height, 2, TOLERANCE, 'the height only the earlier rule set')
end)

spec('an empty rules table is a no-op', function()
  reset()
  rules.setRules {}

  local properties = rules.resolve(newWindow 'terminal')
  expect.equal(next(properties), nil, 'the properties')
end)

spec('a rule matching an absent field does not match rather than raising', function()
  reset()
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { width = 1 } },
  }

  -- No `appId` at all, which is what a client that never set one looks like.
  local properties = rules.resolve { title = 'a window' }
  expect.falsy(properties.width, 'the width')
end)

spec('a match value that is a function is a predicate', function()
  reset()
  rules.setRules {
    {
      match = {
        title = function(value)
          return type(value) == 'string' and value:find 'log'
        end,
      },
      properties = { width = 2 },
    },
  }

  expect.near(rules.resolve(newWindow('any', 'the log')).width, 2, TOLERANCE, 'a matching title')
  expect.falsy(rules.resolve(newWindow('any', 'a shell')).width, 'a title that does not match')
  expect.falsy(rules.resolve(newWindow 'any').width, 'no title at all')
end)

spec('an absent match matches every window', function()
  reset()
  rules.setRules {
    { properties = { chrome = false } },
  }

  expect.equal(rules.resolve(newWindow 'anything').chrome, false, 'the property')
end)

spec('a property that is a function is evaluated at application time', function()
  reset()
  local current = 'first'
  local calls = 0
  rules.setRules {
    {
      properties = {
        title = function()
          calls = calls + 1
          return current
        end,
      },
    },
  }

  expect.equal(calls, 0, 'the calls made while declaring the rule')

  current = 'second'
  expect.equal(rules.resolve(newWindow 'any').title, 'second', 'the title')
  expect.equal(calls, 1, 'the calls made resolving once')
end)

spec('a function a later rule overwrote is never called', function()
  reset()
  local called = false
  rules.setRules {
    {
      properties = {
        width = function()
          called = true
          return 1
        end,
      },
    },
    { properties = { width = 2 } },
  }

  expect.near(rules.resolve(newWindow 'any').width, 2, TOLERANCE, 'the width')
  expect.equal(called, false, 'whether the overwritten function ran')
end)

spec('a function-valued property is handed the window', function()
  reset()
  rules.setRules {
    {
      properties = {
        title = function(window)
          return 'a panel for ' .. window.appId
        end,
      },
    },
  }

  expect.equal(rules.resolve(newWindow 'terminal').title, 'a panel for terminal', 'the title')
end)

spec('a higher-precedence source layers over a lower one', function()
  reset()
  rules.addSource('low', 10, function()
    return { width = 1, height = 5 }
  end)
  rules.addSource('high', 20, function()
    return { width = 2 }
  end)

  local properties = rules.resolve(newWindow 'any')
  expect.near(properties.width, 2, TOLERANCE, 'the width the higher source set')
  expect.near(properties.height, 5, TOLERANCE, 'the height only the lower source set')
end)

spec('sources are applied from the lowest precedence to the highest', function()
  reset()
  rules.addSource('third', 30, function() end)
  rules.addSource('first', 10, function() end)
  rules.addSource('second', 20, function() end)

  local names = {}
  for _, source in ipairs(rules.sources()) do
    names[#names + 1] = source.name
  end
  expect.equal(table.concat(names, ','), 'first,second,third', 'the order')
end)

spec('sources at one precedence apply in registration order', function()
  reset()
  -- More than a couple, because `table.sort` is not stable: a comparator that
  -- called two sources at one precedence equal would be free to permute them,
  -- and with two entries it would happen not to. The order is stated by the
  -- registration tiebreak rather than left to whatever the sort produced.
  local registered = { 'h', 'g', 'f', 'e', 'd', 'c', 'b', 'a' }
  for _, name in ipairs(registered) do
    rules.addSource(name, 10, function()
      return { width = name }
    end)
  end

  local names = {}
  for _, source in ipairs(rules.sources()) do
    names[#names + 1] = source.name
  end
  expect.equal(table.concat(names, ','), table.concat(registered, ','), 'the order')
  expect.equal(rules.resolve(newWindow 'any').width, 'a', 'the value the last source set')
end)

spec('a source registered again replaces the first', function()
  reset()
  rules.addSource('once', 10, function()
    return { width = 1 }
  end)
  rules.addSource('once', 10, function()
    return { width = 2 }
  end)

  expect.equal(#rules.sources(), 1, 'the sources')
  expect.near(rules.resolve(newWindow 'any').width, 2, TOLERANCE, 'the width')
end)

spec('a source can be removed', function()
  reset()
  rules.addSource('once', 10, function()
    return { width = 1 }
  end)

  expect.equal(rules.removeSource 'once', true, 'the removal')
  expect.equal(rules.removeSource 'once', false, 'removing it again')
  expect.equal(#rules.sources(), 0, 'the sources')
end)

spec('a source answering nothing contributes nothing', function()
  reset()
  rules.addSource('quiet', 10, function()
    return nil
  end)
  rules.addSource('loud', 20, function()
    return { width = 1 }
  end)

  expect.near(rules.resolve(newWindow 'any').width, 1, TOLERANCE, 'the width')
end)

spec('a source answering something other than a table raises', function()
  reset()
  rules.addSource('confused', 10, function()
    return 'a width'
  end)

  expect.raises(function()
    rules.resolve(newWindow 'any')
  end, 'answered a string', 'a source answering a string')
end)

spec('a rules list that is not a list of tables raises at declaration', function()
  reset()

  expect.raises(function()
    rules.setRules { 'firefox' }
  end, 'rule 1 is a table', 'a rule that is a string')

  expect.raises(function()
    rules.setRules { { match = 'firefox' } }
  end, 'the match of rule 1', 'a match that is a string')

  expect.raises(function()
    rules.setRules { { properties = 'wide' } }
  end, 'the properties of rule 1', 'properties that are a string')
end)

spec('a source with a precedence that is not orderable raises', function()
  reset()

  expect.raises(function()
    rules.addSource('nowhere', 0 / 0, function() end)
  end, 'orderable number', 'a nan precedence')
end)

spec('placing a window makes a panel at the pose the rule named', function()
  reset()
  local placed = lovr.math.newMat4():translate(1, 1.5, -2)
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { pose = placed, height = 0.6 } },
  }

  local created = rules.place(newWindow 'terminal')

  local x, y, z = created.pose:getPosition()
  expect.near(x, 1, TOLERANCE, 'x')
  expect.near(y, 1.5, TOLERANCE, 'y')
  expect.near(z, -2, TOLERANCE, 'z')
  expect.near(created.height, 0.6, TOLERANCE, 'the metre height')
  expect.equal(#fixture.panel.all(), 1, 'the panels')
end)

-- The regression: a window handle is userdata, not a table, so a guard that
-- insisted on a table raised for every real window. The shipped configuration
-- installs a rules table with a non-nil `match`, which is what reaches this, so
-- every window opening and every window adopted by a reload raised.
spec('placing a window handle that is not a table matches it', function()
  reset()
  local placed = lovr.math.newMat4():translate(1, 1.5, -2)
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { pose = placed, height = 0.6 } },
  }

  local created = rules.place(fixture.asHandle(newWindow 'terminal'))

  local x, y, z = created.pose:getPosition()
  expect.near(x, 1, TOLERANCE, 'x')
  expect.near(y, 1.5, TOLERANCE, 'y')
  expect.near(z, -2, TOLERANCE, 'z')
  expect.equal(#fixture.panel.all(), 1, 'the panels')
end)

-- The other half of the same guard: a match that names a field the handle does
-- not carry answers false rather than raising, whichever shape the handle is.
spec('a window handle that is not a table can fail to match', function()
  reset()
  rules.setRules {
    { match = { appId = 'firefox' }, properties = { width = 2 } },
  }

  local properties = rules.resolve(fixture.asHandle(newWindow 'terminal'))

  expect.equal(properties.width, nil, 'the width of a window no rule matched')
end)

-- A window is indexed, so a value that cannot be indexed is still refused. The
-- fix widens the guard rather than removing it.
spec('a window that is neither a table nor userdata is refused', function()
  reset()
  local ok, message = pcall(rules.matches, { appId = 'terminal' }, 'terminal')

  expect.equal(ok, false, 'whether a string was accepted as a window')
  expect.truthy(message:find 'not a string', 'what was reported')
end)

spec('placing a window accepts an encoded pose', function()
  reset()
  local pose = require 'mullion.pose'
  rules.setRules {
    { properties = { pose = pose.encode(lovr.math.newMat4():translate(0, 2, -3)) } },
  }

  local created = rules.place(newWindow 'terminal')

  local _, y, z = created.pose:getPosition()
  expect.near(y, 2, TOLERANCE, 'y')
  expect.near(z, -3, TOLERANCE, 'z')
end)

spec('a pose that is not sixteen numbers is reported rather than applied', function()
  reset()
  rules.setRules {
    { properties = { pose = 'over there' } },
  }

  local created = rules.place(newWindow 'terminal')

  local x, y, z = created.pose:getPosition()
  expect.near(x, 0, TOLERANCE, 'x')
  expect.near(y, 0, TOLERANCE, 'y')
  expect.near(z, 0, TOLERANCE, 'z')
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'sixteen numbers', 'what was reported')
end)

spec('a rule naming tags puts the panel on them', function()
  reset()
  local declared = tag.new 'declared'
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { tags = { 'declared', 'fresh' } } },
  }

  local created = rules.place(newWindow 'terminal')

  expect.equal(declared:has(created), true, 'membership of the declared tag')
  local fresh = tag.find 'fresh'
  expect.truthy(fresh, 'the tag the rule named and nothing declared')
  expect.equal(fresh:has(created), true, 'membership of the created tag')
end)

spec('a tag a rule names and nothing declared is reported as created', function()
  reset()
  tag.new 'declared'
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { tags = { 'declared', 'fresh' } } },
  }

  rules.place(newWindow 'terminal')

  -- Creating it is the right answer — refusing would lose the window over a
  -- declaration order — but a misspelt name arrives the same way, and a
  -- workspace nobody asked for holding a window nobody can find is worse than
  -- a line of output.
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find "nothing declared the tag 'fresh'", 'what was reported')
end)

spec('a rule naming a tag object puts the panel on it', function()
  reset()
  local main = tag.new 'main'
  rules.setRules {
    {
      properties = {
        tags = function()
          return { main }
        end,
      },
    },
  }

  local created = rules.place(newWindow 'terminal')

  expect.equal(main:has(created), true, 'membership')
end)

spec('a tags value that is not a name or a tag is reported', function()
  reset()
  rules.setRules {
    { properties = { tags = { 42 } } },
  }

  rules.place(newWindow 'terminal')

  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'a tag is named', 'what was reported')
end)

spec('options fill in what no rule set', function()
  reset()
  rules.setRules {
    { properties = { height = 0.5 } },
  }

  local _, properties = rules.place(newWindow 'terminal', { height = 2, priority = 42 })

  expect.near(properties.height, 0.5, TOLERANCE, 'the height a rule set')
  expect.equal(properties.priority, 42, 'the priority only the options set')
end)

spec('properties this module does not know are handed back untouched', function()
  reset()
  rules.setRules {
    { properties = { curvature = 0.3 } },
  }

  local _, properties = rules.place(newWindow 'terminal')
  expect.near(properties.curvature, 0.3, TOLERANCE, 'the property')
end)

spec('teardown discards every source', function()
  reset()
  rules.setRules {
    { properties = { width = 1 } },
  }

  rules.teardown()

  expect.equal(#rules.sources(), 0, 'the sources')
  expect.equal(next(rules.resolve(newWindow 'any')), nil, 'what resolves afterwards')
end)

spec('requiring twice leaves one teardown hook', function()
  reset()
  local teardown = require 'mullion.teardown'
  package.loaded['mullion.rules'] = nil
  local reloaded = require 'mullion.rules'
  package.loaded['mullion.rules'] = rules

  local registered = 0
  for _, name in ipairs(teardown.pending()) do
    if name == 'mullion.rules' then
      registered = registered + 1
    end
  end
  expect.equal(registered, 1, 'the hooks named mullion.rules')
  reloaded.teardown()
  -- The second body's `register` replaced the hook with its own sources', so the
  -- first one's is put back: the rest of the suite holds the first module table.
  teardown.register('mullion.rules', rules.teardown)
end)

return spec
