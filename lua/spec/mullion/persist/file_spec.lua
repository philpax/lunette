-- Covers the file half of lua/mullion/persist/init.lua: the path, the load, the
-- save, and the refusal that keeps a file this version cannot read.
--
-- The acceptance criterion the module carries is that a saved arrangement is
-- restored after a restart, so one case writes a real file into
-- `lovr.filesystem`'s save directory, reads its bytes back off disk, and
-- restores from what it read. A table copied in memory would satisfy a weaker
-- test and none of the criterion. Everything else runs against the in-memory
-- filesystem the seam takes, so the cases about an absent or unwritable file do
-- not depend on the state of a real directory.
--
-- The other half — capture, restore, and the rules source — is
-- `spec/mullion/persist/arrangement_spec.lua`, and the fakes both build are
-- `spec.mullion.persist.fixture`.

local expect = require 'spec.expect'
local fixture = require 'spec.mullion.persist.fixture'
local suite = require 'spec.suite'

local persist = require 'mullion.persist'
local tag = require 'mullion.tag'

local spec = suite.new 'mullion.persist.file'

local TOLERANCE = fixture.TOLERANCE
local reset = fixture.reset
local newEntry = fixture.newEntry
local newFilesystem = fixture.newFilesystem
local fromTheFutureText = fixture.fromTheFutureText

spec('an absent save file is an empty arrangement rather than an error', function()
  reset()
  local loaded = persist.load(newFilesystem(nil))

  expect.equal(loaded.kind, 'arrangement', 'the kind')
  expect.equal(#persist.entries(loaded:forSession()), 0, 'the entries')
  expect.equal(#fixture.reported, 0, 'the reports')
end)

spec('a load from a later version is left on disk rather than overwritten', function()
  reset()
  local newer = fromTheFutureText()
  local filesystem = newFilesystem(newer)

  local loaded = persist.load(filesystem)

  expect.equal(loaded.kind, 'fromTheFuture', 'the kind')
  expect.equal(filesystem.text, newer, 'the file on disk')
  expect.equal(filesystem.writes, 0, 'the writes')
  expect.equal(#fixture.reported, 1, 'the reports')
  expect.truthy(fixture.reported[1]:find 'written by version', 'what was reported')
end)

spec('a broken file on disk is reported rather than raising', function()
  reset()
  local loaded = persist.load(newFilesystem 'return {')

  expect.equal(loaded.kind, 'broken', 'the kind')
  expect.equal(#fixture.reported, 1, 'the reports')
  expect.truthy(fixture.reported[1]:find 'could not be read', 'what was reported')
end)

spec('an entry the format skipped is reported by the load', function()
  reset()
  local text = "return { version = 1, entries = { { kind = 'nothing', key = 'x', pose = 'y' } } }"

  persist.load(newFilesystem(text))

  expect.equal(#fixture.reported, 1, 'the reports')
  expect.truthy(fixture.reported[1]:find 'window or a monitor', 'what was reported')
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

spec('a save after a load from a later version leaves the bytes on disk', function()
  reset()
  local newer = fromTheFutureText()
  local filesystem = newFilesystem(newer)
  persist.load(filesystem)

  -- `capture` is a second constructor of an arrangement, and it builds from live
  -- panels rather than from what was read — so the type that stops the load
  -- being rewritten does not reach here. Without the refusal the shipped
  -- configuration's `lovr.quit` writes version 1 over the newer file.
  local saved, message = persist.save(persist.capture { fixture.newWindowPanel 'terminal' }, filesystem)

  expect.equal(saved, false, 'the outcome')
  expect.truthy(message:find 'written by version', 'the message')
  expect.equal(filesystem.text, newer, 'the file on disk')
  expect.equal(filesystem.writes, 0, 'the writes')
end)

spec('a save after a file that could not be read is refused too', function()
  reset()
  local broken = 'return {'
  local filesystem = newFilesystem(broken)
  persist.load(filesystem)

  local saved, message = persist.save(persist.newFile {}, filesystem)

  expect.equal(saved, false, 'the outcome')
  expect.truthy(message:find 'could not be read', 'the message')
  expect.equal(filesystem.text, broken, 'the file on disk')
  expect.equal(filesystem.writes, 0, 'the writes')
end)

spec('a forced save overwrites a file this version could not read', function()
  reset()
  local filesystem = newFilesystem(fromTheFutureText())
  persist.load(filesystem)

  local saved = persist.save(persist.newFile {}, filesystem, { force = true })

  expect.equal(saved, true, 'the outcome')
  expect.equal(filesystem.writes, 1, 'the writes')
  expect.equal(filesystem.text, persist.render(persist.newFile {}), 'the file on disk')
end)

spec('a load that could be used allows saving again', function()
  reset()
  local filesystem = newFilesystem(fromTheFutureText())
  persist.load(filesystem)
  expect.truthy(persist.declined(), 'the refusal after the newer file')

  -- The user moved the newer file away, which is the way out of the refusal that
  -- does not involve overwriting anything.
  filesystem.text = nil
  persist.load(filesystem)

  expect.falsy(persist.declined(), 'the refusal after the file went')
  expect.equal(persist.save(persist.newFile {}, filesystem), true, 'the save')
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
  local screen = fixture.newMonitorPanel('Acme X24 on DP-1', { pose = placed, width = 1.6 })
  local main = tag.new 'main'
  main:add(screen)

  expect.equal(persist.save(persist.capture { screen }), true, 'the save')
  expect.truthy(lovr.filesystem.isFile(persist.FILE), 'the file in the save directory')

  -- Everything the session held, gone: the panels, the tags, and the arrangement
  -- object. What comes back has to come back off disk.
  reset()

  local recovered = persist.load():forSession()
  expect.truthy(recovered, 'the arrangement read back')

  local reopened = fixture.newMonitorPanel 'Acme X24 on DP-1'
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
