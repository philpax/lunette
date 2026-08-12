-- Covers the arrangement half of lua/mullion/persist/init.lua: the entries a set
-- of panels is captured as, the panels an arrangement is restored onto, and the
-- `mullion.rules` source it is installed as.
--
-- The other half — the file on disk, the load, and the save — is
-- `spec/mullion/persist/file_spec.lua`. The seam is the module's own: one half
-- is arrangements and panels, the other is bytes and a filesystem.
--
-- The fakes both halves build are `spec.mullion.persist.fixture`, which requires
-- the panel fixture, so that the `mullion.panel` this reaches through is the one
-- holding the fake `lunette`.

local expect = require '@spec/expect'
local fixture = require '@spec/mullion/persist/fixture'
local suite = require '@spec/suite'

local persist = require '@mullion/persist'
local pose = require '@mullion/pose'
local rules = require '@mullion/rules'
local tag = require '@mullion/tag'

local spec = suite.new 'mullion.persist.arrangement'

local TOLERANCE = fixture.TOLERANCE
local reset = fixture.reset
local newEntry = fixture.newEntry
local newWindowPanel = fixture.newWindowPanel
local newMonitorPanel = fixture.newMonitorPanel

spec('capture keys a window on its appId and a slot', function()
  reset()
  local first = newWindowPanel('terminal', { id = 1, pose = lovr.math.newMat4():translate(1, 0, 0) })
  local second = newWindowPanel('terminal', { id = 2 })
  local other = newWindowPanel('browser', { id = 1 })

  local entries = persist.entries(persist.capture { first, second, other })

  expect.equal(#entries, 3, 'the entries')
  expect.equal(entries[1].key, 'terminal', 'the first key')
  expect.equal(entries[1].slot, 1, 'the first slot')
  expect.equal(entries[2].slot, 2, 'the second slot')
  expect.equal(entries[3].key, 'browser', 'the third key')
  expect.equal(entries[3].slot, 1, 'the third slot')
end)

spec('capture keys a monitor on its saved identity', function()
  reset()
  local screen = newMonitorPanel 'Acme X24 on DP-1'

  local entries = persist.entries(persist.capture { screen })

  expect.equal(entries[1].kind, 'monitor', 'the kind')
  expect.equal(entries[1].key, 'Acme X24 on DP-1', 'the key')
end)

spec('capture records the tags a panel is on', function()
  reset()
  local main = tag.new 'main'
  local side = tag.new 'side'
  local created = newWindowPanel 'terminal'
  main:add(created)
  side:add(created)

  local entries = persist.entries(persist.capture { created })

  expect.equal(table.concat(entries[1].tags, ','), 'main,side', 'the tags')
end)

spec('a source with no identity is reported rather than saved', function()
  reset()
  local nameless = newWindowPanel 'terminal'
  -- A window also carries an `id`, so a key that fell through to it would name
  -- the compositor's identifier, which names nothing after a restart.
  nameless.source.appId = nil

  local entries = persist.entries(persist.capture { nameless })

  expect.equal(#entries, 0, 'the entries')
  expect.equal(#fixture.reported, 1, 'the reports')
  expect.truthy(fixture.reported[1]:find 'no identity', 'what was reported')
end)

spec('a destroyed panel is not captured', function()
  reset()
  local created = newWindowPanel 'terminal'
  created:destroy()

  expect.equal(#persist.entries(persist.capture { created }), 0, 'the entries')
end)

spec('restore puts a monitor panel back and reports what did not match', function()
  reset()
  local file = persist.newFile {
    newEntry {
      kind = 'monitor',
      key = 'Acme X24 on DP-1',
      pose = pose.encode(lovr.math.newMat4():translate(-1, 2, -3)),
      tags = {},
    },
    newEntry { kind = 'monitor', key = 'a screen that is unplugged', tags = {} },
  }
  local screen = newMonitorPanel 'Acme X24 on DP-1'

  local restored, stale = persist.restore(file, { screen })

  expect.equal(#restored, 1, 'the panels restored')
  local x, y, z = screen.pose:getPosition()
  expect.near(x, -1, TOLERANCE, 'x')
  expect.near(y, 2, TOLERANCE, 'y')
  expect.near(z, -3, TOLERANCE, 'z')
  expect.near(screen.width, 1.2, TOLERANCE, 'the metre width')
  expect.equal(#stale, 1, 'the stale entries')
  expect.equal(stale[1].key, 'a screen that is unplugged', 'the stale key')
  expect.equal(#fixture.reported, 1, 'the reports')
  expect.truthy(fixture.reported[1]:find 'nothing matched', 'what was reported')
end)

spec('restore puts a panel back on the tags it was on', function()
  reset()
  local file = persist.newFile { newEntry { kind = 'monitor', key = 'a screen', tags = { 'main' } } }
  local screen = newMonitorPanel 'a screen'

  persist.restore(file, { screen })

  local main = tag.find 'main'
  expect.truthy(main, 'the tag the entry named')
  expect.equal(main:has(screen), true, 'membership')
end)

spec('restore skips an entry whose pose is not sixteen numbers', function()
  reset()
  local file = persist.newFile { newEntry { kind = 'monitor', key = 'a screen', pose = 'over there', tags = {} } }
  local screen = newMonitorPanel 'a screen'

  local restored, stale = persist.restore(file, { screen })

  expect.equal(#restored, 0, 'the panels restored')
  expect.equal(#stale, 1, 'the stale entries')
end)

spec('a destroyed panel takes no slot from a live one', function()
  reset()
  -- The dead panel is first, so a restore that counted it would give the live
  -- one slot two and leave the entry unmatched.
  local file = persist.newFile {
    newEntry { kind = 'monitor', key = 'a screen', slot = 1, tags = {} },
  }
  local gone = newMonitorPanel 'a screen'
  gone:destroy()
  local screen = newMonitorPanel 'a screen'

  local restored, stale = persist.restore(file, { gone, screen })

  expect.equal(#restored, 1, 'the panels restored')
  expect.equal(restored[1], screen, 'the panel restored')
  expect.equal(#stale, 0, 'the stale entries')
end)

spec('apply refuses a destroyed panel', function()
  reset()
  -- Checked here as well as in `restore`, which is the layer that would
  -- ordinarily have skipped it: a configuration applying an entry itself reaches
  -- this directly, and a panel can be destroyed between the two calls.
  local screen = newMonitorPanel 'a screen'
  screen:destroy()

  expect.equal(persist.apply(newEntry { kind = 'monitor', key = 'a screen', tags = {} }, screen), false, 'the outcome')
end)

spec('a key running into a slot does not collide with another entry', function()
  reset()
  -- 'a' at slot 11 and 'a1' at slot 1 would be one lookup if the parts of a key
  -- were concatenated without a separator, and the second window would be placed
  -- where the eleventh one was.
  -- The colliding entry is written second, so a lookup that ran the parts
  -- together would answer with it rather than with the one asked for.
  local file = persist.newFile {
    newEntry { key = 'a1', slot = 1, width = 2 },
    newEntry { key = 'a', slot = 11, width = 1 },
  }
  local resolve = persist.source(file)

  expect.near(resolve({ appId = 'a1', id = 1 }).width, 2, TOLERANCE, 'the width of the a1 window')
end)

spec('the restore source gives a window the properties it was saved with', function()
  reset()
  local file = persist.newFile { newEntry() }
  local resolve = persist.source(file)

  local properties = resolve { appId = 'terminal', id = 7 }

  expect.equal(properties.pose, persist.entries(file)[1].pose, 'the pose')
  expect.near(properties.width, 1.2, TOLERANCE, 'the width')
  expect.equal(properties.tags[1], 'main', 'the tag')
end)

spec('the restore source gives each window of one appId its own entry', function()
  reset()
  local file = persist.newFile {
    newEntry { slot = 1, width = 1 },
    newEntry { slot = 2, width = 2 },
  }
  local resolve = persist.source(file)

  expect.near(resolve({ appId = 'terminal', id = 1 }).width, 1, TOLERANCE, 'the first window')
  expect.near(resolve({ appId = 'terminal', id = 2 }).width, 2, TOLERANCE, 'the second window')
  expect.falsy(resolve { appId = 'terminal', id = 3 }, 'a third window with no entry left')
end)

spec('the restore source answers the same window the same entry twice', function()
  reset()
  local file = persist.newFile {
    newEntry { slot = 1, width = 1 },
    newEntry { slot = 2, width = 2 },
  }
  local resolve = persist.source(file)

  expect.near(resolve({ appId = 'terminal', id = 1 }).width, 1, TOLERANCE, 'the first resolve')
  expect.near(resolve({ appId = 'terminal', id = 1 }).width, 1, TOLERANCE, 'the second resolve')
  -- The second resolve consumed nothing, so the next window still finds slot 2.
  expect.near(resolve({ appId = 'terminal', id = 2 }).width, 2, TOLERANCE, 'the second window')
end)

spec('the restore source contributes nothing for a window it never saw', function()
  reset()
  local resolve = persist.source(persist.newFile { newEntry() })

  expect.falsy(resolve { appId = 'browser', id = 1 }, 'an application with no entry')
  expect.falsy(resolve { id = 1 }, 'a window with no appId at all')
end)

spec('a restored pose beats the rule that would have placed the window', function()
  reset()
  local file = persist.newFile {
    newEntry { pose = pose.encode(lovr.math.newMat4():translate(3, 3, -3)) },
  }
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { pose = lovr.math.newMat4():translate(0, 0, -1) } },
  }
  persist.install(file)

  local created = rules.place(fixture.newWindow 'terminal')

  local x, y, z = created.pose:getPosition()
  expect.near(x, 3, TOLERANCE, 'x')
  expect.near(y, 3, TOLERANCE, 'y')
  expect.near(z, -3, TOLERANCE, 'z')
end)

spec('a configuration can declare that the rules beat the restore instead', function()
  reset()
  local file = persist.newFile {
    newEntry { pose = pose.encode(lovr.math.newMat4():translate(3, 3, -3)) },
  }
  rules.setRules {
    { match = { appId = 'terminal' }, properties = { pose = lovr.math.newMat4():translate(0, 0, -1) } },
  }
  persist.install(file, rules.DEFAULT_PRECEDENCE - 1)

  local created = rules.place(fixture.newWindow 'terminal')

  local _, _, z = created.pose:getPosition()
  expect.near(z, -1, TOLERANCE, 'z')
end)

spec('install accepts what load returns, as the default configuration passes it', function()
  reset()
  -- `etc/xdg/lunette/main.lua` writes `persist.install(persist.load())`, which
  -- is the shape a configuration reaches for. A load and an arrangement are two
  -- different things, and an install that only took the second raises here — on
  -- the first frame of every fresh installation.
  local saved = persist.newFile {
    newEntry { pose = pose.encode(lovr.math.newMat4():translate(3, 3, -3)) },
  }
  persist.install(persist.load(fixture.newFilesystem(persist.render(saved))))

  local created = rules.place(fixture.newWindow 'terminal')

  local x, y, z = created.pose:getPosition()
  expect.near(x, 3, TOLERANCE, 'x')
  expect.near(y, 3, TOLERANCE, 'y')
  expect.near(z, -3, TOLERANCE, 'z')
  -- The entry named a tag nothing declared, which `mullion.rules` creates and
  -- reports. Asserted so that the report is a decision rather than noise.
  expect.equal(#fixture.ruleReports, 1, 'what mullion.rules reported')
  expect.truthy(fixture.ruleReports[1]:find 'nothing declared the tag', 'what was reported')
end)

spec('install accepts a load carrying no arrangement at all', function()
  reset()
  -- `forSession` answers nothing for a load this version cannot read, so a
  -- configuration passing a load through without an `or` hands nil onwards. That
  -- is a session with nothing to restore, not a session that fails to start.
  persist.install(persist.load(fixture.newFilesystem(fixture.fromTheFutureText())))
  persist.install(nil, rules.DEFAULT_PRECEDENCE + 1)

  expect.equal(next(rules.resolve(fixture.newWindow 'terminal')), nil, 'the properties an empty restore contributed')
end)

spec('restore of a load carrying no arrangement places nothing rather than raising', function()
  reset()
  local screen = newMonitorPanel 'a screen'

  local restored, stale = persist.restore(persist.load(fixture.newFilesystem(fixture.fromTheFutureText())), { screen })

  expect.equal(#restored, 0, 'the panels restored')
  expect.equal(#stale, 0, 'the stale entries')
end)

return spec
