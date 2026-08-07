-- Covers lua/mullion/persist/init.lua.
--
-- The acceptance criterion this module carries is that a saved arrangement is
-- restored after a restart, so one case writes a real file into
-- `lovr.filesystem`'s save directory, reads its bytes back off disk, and
-- restores from what it read. A table copied in memory would satisfy a weaker
-- test and none of the criterion.
--
-- The panel fixture is required first, so that the `mullion.panel` this reaches
-- through is the one holding the fake `lunette`.

local expect = require 'spec.expect'
local fixture = require 'spec.mullion.panel.fixture'
local suite = require 'spec.suite'

local persist = require 'mullion.persist'
local pose = require 'mullion.pose'
local rules = require 'mullion.rules'
local tag = require 'mullion.tag'

local spec = suite.new 'mullion.persist'

local TOLERANCE = 1e-5

-- What `persist.report` was told, so that a case can assert an entry was
-- reported rather than let it print into the run's output.
local reported = {}

local function reset()
  rules.teardown()
  tag.teardown()
  fixture.reset()
  reported = {}
  persist.report = function(message)
    reported[#reported + 1] = message
  end
end

-- A window panel over a source with the given application identifier.
local function newWindowPanel(appId, options)
  local window = fixture.newWindow(800, 600)
  window.appId = appId
  window.id = appId .. '-' .. tostring(options and options.id or 1)
  return fixture.panel.fromWindow(window, options)
end

-- A monitor panel over a screen with the given saved identity.
local function newMonitorPanel(id, options)
  local monitor = fixture.newSource(1920, 1080)
  monitor.id = id
  return fixture.panel.fromMonitor(monitor, options)
end

-- A filesystem that holds one file in memory, so that the cases about an absent
-- or unwritable file do not depend on the state of a real directory.
local function newFilesystem(text)
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

local function newEntry(overrides)
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
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'no identity', 'what was reported')
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
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'nothing matched', 'what was reported')
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

  local window = fixture.newWindow(800, 600)
  window.appId, window.id = 'terminal', 1
  local created = rules.place(window)

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

  local window = fixture.newWindow(800, 600)
  window.appId, window.id = 'terminal', 1
  local created = rules.place(window)

  local _, _, z = created.pose:getPosition()
  expect.near(z, -1, TOLERANCE, 'z')
end)

spec('an absent save file is an empty arrangement rather than an error', function()
  reset()
  local loaded = persist.load(newFilesystem(nil))

  expect.equal(loaded.kind, 'arrangement', 'the kind')
  expect.equal(#persist.entries(loaded:forSession()), 0, 'the entries')
  expect.equal(#reported, 0, 'the reports')
end)

spec('a load from a later version is left on disk rather than overwritten', function()
  reset()
  local newer = 'return { version = ' .. (persist.CURRENT_VERSION + 1) .. ', entries = {}, curvature = 0.3 }'
  local filesystem = newFilesystem(newer)

  local loaded = persist.load(filesystem)

  expect.equal(loaded.kind, 'fromTheFuture', 'the kind')
  expect.equal(filesystem.text, newer, 'the file on disk')
  expect.equal(filesystem.writes, 0, 'the writes')
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'written by version', 'what was reported')
end)

spec('a broken file on disk is reported rather than raising', function()
  reset()
  local loaded = persist.load(newFilesystem 'return {')

  expect.equal(loaded.kind, 'broken', 'the kind')
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'could not be read', 'what was reported')
end)

spec('an entry the format skipped is reported by the load', function()
  reset()
  local text = "return { version = 1, entries = { { kind = 'nothing', key = 'x', pose = 'y' } } }"

  persist.load(newFilesystem(text))

  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1]:find 'window or a monitor', 'what was reported')
end)

spec('save refuses anything that is not an arrangement this module made', function()
  reset()

  expect.raises(function()
    persist.save({ version = 1, entries = {} }, newFilesystem())
  end, 'an arrangement is one this module made', 'a plain table')
end)

spec('a save that could not be written says so rather than reporting success', function()
  reset()
  local filesystem = newFilesystem(nil)
  filesystem.writable = false

  local saved, message = persist.save(persist.newFile {}, filesystem)

  expect.equal(saved, false, 'the outcome')
  expect.truthy(message:find 'could not be written', 'the message')
end)

spec('the save path is under the save directory rather than the source', function()
  reset()
  local path = persist.path()

  expect.equal(path, lovr.filesystem.getSaveDirectory() .. '/' .. persist.FILE, 'the path')
  -- Not the configuration directory: the save directory derives from the
  -- identity and the source is the config, so a path that was assumed rather
  -- than asked for would write into the user's configuration.
  expect.falsy(path:find(lovr.filesystem.getSource() or 'nothing', 1, true), 'the source in the save path')
  -- No `.lua`, so a session cannot write something the require path resolves.
  expect.falsy(persist.FILE:find '%.lua$', 'a module extension')
end)

spec('an arrangement written to the save directory is restored by a later load', function()
  reset()
  -- The criterion is that a saved arrangement survives a restart, so this goes
  -- through a real file: `persist.save` writes into `lovr.filesystem`'s save
  -- directory, the bytes are read back off disk, and the restore is from what
  -- was read rather than from the table that was written.
  local placed = lovr.math.newMat4():translate(-0.5, 1.75, -2.25)
  local screen = newMonitorPanel('Acme X24 on DP-1', { pose = placed, width = 1.6 })
  local main = tag.new 'main'
  main:add(screen)

  expect.equal(persist.save(persist.capture { screen }), true, 'the save')
  expect.truthy(lovr.filesystem.isFile(persist.FILE), 'the file in the save directory')

  -- Everything the session held, gone: the panels, the tags, and the arrangement
  -- object. What comes back has to come back off disk.
  fixture.reset()
  tag.teardown()

  local recovered = persist.load():forSession()
  expect.truthy(recovered, 'the arrangement read back')

  local reopened = newMonitorPanel 'Acme X24 on DP-1'
  local restored, stale = persist.restore(recovered, { reopened })

  expect.equal(#restored, 1, 'the panels restored')
  expect.equal(#stale, 0, 'the stale entries')
  local x, y, z = reopened.pose:getPosition()
  expect.near(x, -0.5, TOLERANCE, 'x')
  expect.near(y, 1.75, TOLERANCE, 'y')
  expect.near(z, -2.25, TOLERANCE, 'z')
  expect.near(reopened.width, 1.6, TOLERANCE, 'the metre width')
  expect.equal(tag.find('main'):has(reopened), true, 'the tag it was on')

  lovr.filesystem.remove(persist.FILE)
end)

spec('the bytes on disk are the arrangement this version renders', function()
  reset()
  local file = persist.newFile { newEntry() }

  expect.equal(persist.save(file), true, 'the save')
  expect.equal(lovr.filesystem.read(persist.FILE), persist.render(file), 'the bytes written')

  lovr.filesystem.remove(persist.FILE)
end)

return spec
