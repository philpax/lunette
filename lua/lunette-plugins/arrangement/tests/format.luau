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

  local recovered = format.read(format.render(written)).file

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

  local entry = format.entries(format.read(format.render(written)).file)[1]
  expect.falsy(entry.width, 'the width')
  expect.falsy(entry.height, 'the height')
end)

test('a size round-trips to the last digit', function()
  -- Exact precision prevents panel dimensions from drifting across restarts.
  local width, height = 1 / 3, 0.8999999999999999
  local written = format.newFile { newEntry { width = width, height = height } }

  local entry = format.entries(format.read(format.render(written)).file)[1]
  expect.near(entry.width, width, 0, 'the width')
  expect.near(entry.height, height, 0, 'the height')
end)

test('render always writes the current version', function()
  local text = format.render(format.newFile {})

  expect.truthy(text:find('version = ' .. format.VERSION, 1, true), 'the version')
  expect.equal(format.read(text).kind, 'arrangement', 'the kind')
end)

test('a file from a later version carries no arrangement to write back', function()
  local text = 'return { version = ' .. (format.VERSION + 1) .. ', entries = {}, curvature = 0.3 }'

  local loaded = format.read(text)

  expect.equal(loaded.kind, 'fromTheFuture', 'the kind')
  expect.equal(loaded.found, format.VERSION + 1, 'the version found')
  -- No writable arrangement prevents an old reader from dropping newer fields.
  expect.falsy(loaded.file, 'the arrangement')
end)

test('a broken file is a broken load rather than a raise', function()
  expect.equal(format.read('return {').kind, 'broken', 'a truncated chunk')
  expect.equal(format.read('return 4').kind, 'broken', 'a chunk holding a number')
  expect.equal(format.read('return { entries = {} }').kind, 'broken', 'a file with no version')
  expect.equal(format.read('return { version = 0, entries = {} }').kind, 'broken', 'a version below the first')
  expect.equal(format.read('return { version = 1 }').kind, 'broken', 'a file with no entry list')
  expect.falsy(format.read('return {').file, 'the arrangement of a broken load')
end)

test('a file chunk cannot reach anything outside itself', function()
  -- An empty environment prevents file chunks from accessing runtime modules.
  local loaded = format.read "require 'os'; return { version = 1, entries = {} }"

  expect.equal(loaded.kind, 'broken', 'the kind')
  expect.truthy(loaded.message:find 'nil value', 'what the chunk hit')
end)

test('an entry that is not the shape is refused and named while the rest loads', function()
  -- Hand-edited files and files from other versions can contain malformed entries.
  local pose = newEntry().pose
  local function stored(fields)
    return '    { ' .. fields .. ' },\n'
  end
  local text = 'return {\n  version = 1,\n  entries = {\n'
    .. stored("kind = 'window', key = 'terminal', slot = 1, pose = '" .. pose .. "', tags = {}")
    .. stored "kind = 'terminal', key = 'k', slot = 1, pose = 'x', tags = {}"
    .. stored "kind = 'window', key = 'no pose', slot = 1, tags = {}"
    .. stored "kind = 'window', slot = 1, pose = 'x', tags = {}"
    .. "    'not an entry at all',\n"
    .. stored("kind = 'window', key = 'no slot', pose = '" .. pose .. "', tags = {}")
    .. stored("kind = 'window', key = 'bad size', slot = 1, pose = '" .. pose .. "', width = 'wide', tags = {}")
    .. stored("kind = 'window', key = 'bad tag', slot = 1, pose = '" .. pose .. "', tags = { 'main', 4 }")
    .. stored("kind = 'window', key = 'no tags', slot = 1, pose = '" .. pose .. "'")
    .. '  },\n}'

  local loaded = format.read(text)

  local entries = loaded.file.entries
  expect.equal(#entries, 1, 'the entries')
  expect.equal(entries[1].key, 'terminal', 'the entry that survived')
  local reasons = {
    'window or a monitor',
    'carries no pose',
    'keyed by a name',
    'an entry is a table',
    'has no slot',
    'size that is not',
    'tag 2 that is not',
    'no tag list',
  }
  expect.equal(#loaded.skipped, #reasons, 'the entries refused')
  for index, reason in reasons do
    expect.truthy(loaded.skipped[index]:find(reason, 1, true), 'refusal ' .. index)
  end
end)

return test
