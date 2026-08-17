-- Covers lua/mullion/persist/format.lua.
--
-- The case that matters most is the one nobody writes: an old reader handed a
-- new file must not rewrite it, because a default would let it parse the file
-- and then drop on write-back the fields it did not know about. Here that is
-- checked as the absence of anything writable rather than as a rule somebody
-- remembered to follow.
--
-- The round-trip earns its place: this is a file format that outlives the
-- process, which is exactly the case a round-trip test is for.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local format = require '@mullion/persist/format'
local pose = require '@mullion/pose'

local spec = suite.new 'mullion.persist.format'

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

spec('an arrangement round-trips through render and read', function()
  local written = format.newFile {
    newEntry(),
    newEntry { kind = 'monitor', key = 'Acme X24 on DP-1', tags = {} },
  }

  local recovered = format.read(format.render(written)):forSession()

  local entries = format.entries(recovered)
  expect.equal(#entries, 2, 'the entries')
  for index, entry in ipairs(entries) do
    local original = format.entries(written)[index]
    expect.equal(entry.kind, original.kind, 'the kind of entry ' .. index)
    expect.equal(entry.key, original.key, 'the key of entry ' .. index)
    expect.equal(entry.slot, original.slot, 'the slot of entry ' .. index)
    expect.equal(entry.pose, original.pose, 'the pose of entry ' .. index)
    expect.near(entry.width, original.width, 0, 'the width of entry ' .. index)
    expect.near(entry.height, original.height, 0, 'the height of entry ' .. index)
    expect.equal(#entry.tags, #original.tags, 'the tags of entry ' .. index)
  end
  expect.equal(entries[1].tags[1], 'main', 'the tag name')
end)

spec('an entry with no size round-trips as one with no size', function()
  -- Built rather than overridden, because a table constructor cannot carry a nil
  -- and `newEntry` would not see the key at all.
  local written = format.newFile {
    { kind = 'window', key = 'terminal', slot = 1, pose = pose.encode(lovr.math.newMat4()), tags = {} },
  }

  local entry = format.entries(format.read(format.render(written)):forSession())[1]
  expect.falsy(entry.width, 'the width')
  expect.falsy(entry.height, 'the height')
end)

spec('a size round-trips to the last digit', function()
  -- A metre size that lost its last digit would shrink a panel a little at every
  -- restart, and the drift would be diagnosed as a layout defect rather than as
  -- a formatting one.
  local width, height = 1 / 3, 0.8999999999999999
  local written = format.newFile { newEntry { width = width, height = height } }

  local entry = format.entries(format.read(format.render(written)):forSession())[1]
  expect.near(entry.width, width, 0, 'the width')
  expect.near(entry.height, height, 0, 'the height')
end)

spec('an arrangement does not share an array with its caller', function()
  -- In both directions: what `newFile` was handed and what `entries` hands back
  -- are copies, so a caller sorting or trimming a list does not quietly rewrite
  -- the arrangement that is about to be saved.
  local given = { newEntry() }
  local file = format.newFile(given)
  table.remove(given)
  expect.equal(#format.entries(file), 1, 'the entries after the given array was trimmed')

  local entries = format.entries(file)
  table.remove(entries)
  expect.equal(#format.entries(file), 1, 'the entries after the answered array was trimmed')
end)

spec('render always writes the current version', function()
  local loaded = format.read(format.render(format.newFile {}))

  expect.equal(loaded.kind, 'arrangement', 'the kind')
  expect.equal(loaded.version, format.CURRENT_VERSION, 'the version')
end)

spec('render refuses anything that is not an arrangement this module made', function()
  expect.raises(function()
    format.render { version = 1, entries = {} }
  end, 'an arrangement is one this module made', 'a plain table')

  expect.falsy(format.isFile { entries = {} }, 'a plain table')
  expect.truthy(format.isFile(format.newFile {}), 'an arrangement')
end)

spec('newFile refuses an entry that is not a table', function()
  expect.raises(function()
    format.newFile { 'terminal' }
  end, 'entry 1 is a table', 'a string entry')
end)

spec('a file from a later version carries no arrangement to write back', function()
  local text = 'return { version = ' .. (format.CURRENT_VERSION + 1) .. ', entries = {}, curvature = 0.3 }'

  local loaded = format.read(text)

  expect.equal(loaded.kind, 'fromTheFuture', 'the kind')
  expect.equal(loaded.found, format.CURRENT_VERSION + 1, 'the version found')
  expect.equal(loaded.supported, format.CURRENT_VERSION, 'the version supported')
  -- The whole of the old-writer guard: nothing to render, so nothing `save`
  -- accepts, so the field this version has never heard of cannot be dropped on
  -- write-back.
  expect.falsy(loaded:forSession(), 'the arrangement')
end)

spec('a broken file is a broken load rather than a raise', function()
  expect.equal(format.read('return {').kind, 'broken', 'a truncated chunk')
  expect.equal(format.read('return 4').kind, 'broken', 'a chunk holding a number')
  expect.equal(format.read('return { entries = {} }').kind, 'broken', 'a file with no version')
  expect.equal(format.read('return { version = 0, entries = {} }').kind, 'broken', 'a version below the first')
  expect.equal(format.read(nil).kind, 'broken', 'nothing at all')
  expect.falsy(format.read('return {'):forSession(), 'the arrangement of a broken load')
end)

spec('a file chunk cannot reach anything outside itself', function()
  -- Data this process wrote, read as though it were not: the chunk runs under an
  -- empty environment, so a `require` that found its way into the file raises
  -- inside `read` rather than running.
  local loaded = format.read "require 'os'; return { version = 1, entries = {} }"

  expect.equal(loaded.kind, 'broken', 'the kind')
  expect.truthy(loaded.message:find 'nil value', 'what the chunk hit')
end)

spec('an entry that is not the shape is skipped and named while the rest loads', function()
  -- Written by hand rather than through `render`, because these are shapes this
  -- version does not write and a reader has to survive anyway: a file edited by
  -- hand, or one written by a version that spelt an entry differently.
  local text = [[return {
  version = 1,
  entries = {
    { kind = 'window', key = 'terminal', slot = 1, pose = ']] .. newEntry().pose .. [[', tags = {} },
    { kind = 'terminal', key = 'a kind this version never wrote', slot = 1, pose = 'x', tags = {} },
    { kind = 'window', key = 'an entry with no pose', slot = 1, tags = {} },
    { kind = 'window', slot = 1, pose = 'x', tags = {} },
    'not an entry at all',
  },
}]]

  local loaded = format.read(text)

  local entries = format.entries(loaded:forSession())
  expect.equal(#entries, 1, 'the entries')
  expect.equal(entries[1].key, 'terminal', 'the entry that survived')
  expect.equal(#loaded.skipped, 4, 'the entries skipped')
  expect.truthy(loaded.skipped[1]:find 'window or a monitor', 'the kind that was refused')
  expect.truthy(loaded.skipped[2]:find 'carries no pose', 'the missing pose')
  expect.truthy(loaded.skipped[3]:find 'keyed by a name', 'the missing key')
  expect.truthy(loaded.skipped[4]:find 'an entry is a table', 'the entry that was not one')
end)

spec('an entry with a slot that is not a number takes the first slot', function()
  local text = "return { version = 1, entries = { { kind = 'window', key = 'terminal', pose = 'x' } } }"

  local entry = format.entries(format.read(text):forSession())[1]
  expect.equal(entry.slot, 1, 'the slot')
end)

spec('a load and an arrangement are told apart', function()
  -- The two are what a caller holding the wrong one confuses, and the shipped
  -- configuration hands a load where an arrangement is wanted. Telling them
  -- apart is what lets that be unwrapped rather than raised on.
  local loaded = format.empty()
  local file = loaded:forSession()

  expect.equal(format.isLoaded(loaded), true, 'a load')
  expect.equal(format.isFile(loaded), false, 'a load as an arrangement')
  expect.equal(format.isFile(file), true, 'an arrangement')
  expect.equal(format.isLoaded(file), false, 'an arrangement as a load')
  expect.equal(format.isLoaded(format.broken 'x'), true, 'a broken load')
  expect.equal(format.isLoaded { kind = 'arrangement' }, false, 'a plain table shaped like one')
  expect.equal(format.isLoaded(nil), false, 'nothing at all')
end)

spec('an empty load carries an arrangement with nothing in it', function()
  local loaded = format.empty()

  expect.equal(loaded.kind, 'arrangement', 'the kind')
  expect.equal(#format.entries(loaded:forSession()), 0, 'the entries')
  expect.equal(#loaded.skipped, 0, 'the entries skipped')
end)

spec('every field the format names is written', function()
  -- `renderEntry` reads the entry by name, so a field added to `ENTRY_FIELDS`
  -- and not to that table would be dropped from the file in silence. This is
  -- what makes the two lists disagree loudly instead.
  local rendered = format.render(format.newFile {
    {
      kind = 'window',
      key = 'firefox',
      slot = 1,
      pose = '1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1',
      width = 1.5,
      height = 0.9,
      tags = { 'web' },
    },
  })

  for _, name in ipairs(format.ENTRY_FIELDS) do
    expect.truthy(rendered:find(name .. ' = ', 1, true), 'the field ' .. name)
  end
  expect.truthy(rendered:find('tags = ', 1, true), 'the tags')
end)

return spec
