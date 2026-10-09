local testing = require '@testing'
local expect = testing.expect

local format = require '@lunette-plugins/arrangement/format'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

local function newEntry(overrides)
  local entry = {
    kind = 'window',
    key = 'terminal',
    slot = 1,
    pose = vocabulary.encodePose(lovr.math.newMat4():translate(1, 1.5, -2)),
    width = 1.2,
    height = 0.7,
    tags = { 'main' },
  }
  for key, value in pairs(overrides or {}) do
    entry[key] = value
  end
  return entry
end

test('an arrangement round-trips through render and read', function()
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

test('an entry with no size round-trips as one with no size', function()
  local written = format.newFile {
    { kind = 'window', key = 'terminal', slot = 1, pose = vocabulary.encodePose(lovr.math.newMat4()), tags = {} },
  }

  local entry = format.entries(format.read(format.render(written)):forSession())[1]
  expect.falsy(entry.width, 'the width')
  expect.falsy(entry.height, 'the height')
end)

test('a size round-trips to the last digit', function()
  -- Exact precision prevents panel dimensions from drifting across restarts.
  local width, height = 1 / 3, 0.8999999999999999
  local written = format.newFile { newEntry { width = width, height = height } }

  local entry = format.entries(format.read(format.render(written)):forSession())[1]
  expect.near(entry.width, width, 0, 'the width')
  expect.near(entry.height, height, 0, 'the height')
end)

test('an arrangement does not share an array with its caller', function()
  -- Mutating either returned or input arrays must not change the file.
  local given = { newEntry() }
  local file = format.newFile(given)
  table.remove(given)
  expect.equal(#format.entries(file), 1, 'the entries after the given array was trimmed')

  local entries = format.entries(file)
  table.remove(entries)
  expect.equal(#format.entries(file), 1, 'the entries after the answered array was trimmed')
end)

test('render always writes the current version', function()
  local loaded = format.read(format.render(format.newFile {}))

  expect.equal(loaded.kind, 'arrangement', 'the kind')
  expect.equal(loaded.version, format.CURRENT_VERSION, 'the version')
end)

test('render refuses anything that is not an arrangement this module made', function()
  expect.raises(function()
    format.render { version = 1, entries = {} }
  end, 'an arrangement is one this module made', 'a plain table')

  expect.falsy(format.isFile { entries = {} }, 'a plain table')
  expect.truthy(format.isFile(format.newFile {}), 'an arrangement')
end)

test('newFile refuses an entry that is not a table', function()
  expect.raises(function()
    format.newFile { 'terminal' }
  end, 'entry 1 is a table', 'a string entry')
end)

test('a file from a later version carries no arrangement to write back', function()
  local text = 'return { version = ' .. (format.CURRENT_VERSION + 1) .. ', entries = {}, curvature = 0.3 }'

  local loaded = format.read(text)

  expect.equal(loaded.kind, 'fromTheFuture', 'the kind')
  expect.equal(loaded.found, format.CURRENT_VERSION + 1, 'the version found')
  expect.equal(loaded.supported, format.CURRENT_VERSION, 'the version supported')
  -- No writable arrangement prevents an old reader from dropping newer fields.
  expect.falsy(loaded:forSession(), 'the arrangement')
end)

test('a broken file is a broken load rather than a raise', function()
  expect.equal(format.read('return {').kind, 'broken', 'a truncated chunk')
  expect.equal(format.read('return 4').kind, 'broken', 'a chunk holding a number')
  expect.equal(format.read('return { entries = {} }').kind, 'broken', 'a file with no version')
  expect.equal(format.read('return { version = 0, entries = {} }').kind, 'broken', 'a version below the first')
  expect.equal(format.read(nil).kind, 'broken', 'nothing at all')
  expect.falsy(format.read('return {'):forSession(), 'the arrangement of a broken load')
end)

test('a file chunk cannot reach anything outside itself', function()
  -- An empty environment prevents file chunks from accessing runtime modules.
  local loaded = format.read "require 'os'; return { version = 1, entries = {} }"

  expect.equal(loaded.kind, 'broken', 'the kind')
  expect.truthy(loaded.message:find 'nil value', 'what the chunk hit')
end)

test('an entry that is not the shape is skipped and named while the rest loads', function()
  -- Hand-edited files and files from other versions can contain malformed entries.
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

test('an entry with a slot that is not a number takes the first slot', function()
  local text = "return { version = 1, entries = { { kind = 'window', key = 'terminal', pose = 'x' } } }"

  local entry = format.entries(format.read(text):forSession())[1]
  expect.equal(entry.slot, 1, 'the slot')
end)

test('a load and an arrangement are told apart', function()
  -- Load and arrangement values have distinct runtime identities.
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

test('an empty load carries an arrangement with nothing in it', function()
  local loaded = format.empty()

  expect.equal(loaded.kind, 'arrangement', 'the kind')
  expect.equal(#format.entries(loaded:forSession()), 0, 'the entries')
  expect.equal(#loaded.skipped, 0, 'the entries skipped')
end)

return test
