local testing = require '@testing'
local versionedFile = require '../versioned-file'
local savedSettings = require '../saved-settings'
local expect = testing.expect
local test = testing.suite()

-- The messages reported since the last call, through the fake native API.
local function reported(native: testing.Native): { string }
  local messages: { string } = {}
  for _, report in native.events.reported do
    messages[#messages + 1] = report.message
  end
  table.clear(native.events.reported)
  return messages
end

test('data round-trips through the file, including vectors and nested tables', function()
  local data = {
    entries = {
      ['desktop/errors'] = { position = vector.create(0.5, 1.25, -2), width = 1.2 },
      theme = { mode = 'light', accent = { 0.9, 0.55, 0.65, 1 } },
    },
  }
  local loaded = versionedFile.parse(versionedFile.render(data, 1), 'fixture', 1)
  assert(loaded.kind == 'data', 'the file parses')
  local entries = loaded.data.entries
  expect.equal(entries.theme.mode, 'light')
  expect.equal(entries.theme.accent[2], 0.55)
  local position = entries['desktop/errors'].position
  expect.equal(type(position), 'vector', 'a vector reads back as a vector')
  expect.equal(position.z, -2)
end)

test('a broken, foreign, or newer file is told apart, and the file runs with nothing but vector', function()
  expect.equal(versionedFile.parse('return (', 'fixture', 1).kind, 'broken')
  expect.equal(versionedFile.parse('error("no")', 'fixture', 1).kind, 'broken')
  expect.equal(versionedFile.parse('return { version = 1, data = { x = os.exit() } }', 'fixture', 1).kind, 'broken')
  expect.equal(versionedFile.parse('return { settings = {} }', 'fixture', 1).kind, 'broken')
  local future = versionedFile.parse('return { version = 3, data = {} }', 'fixture', 2)
  assert(future.kind == 'fromTheFuture')
  expect.equal(future.found, 3)
  expect.equal(versionedFile.literal(function() end), false, 'a function is not a literal')
  expect.equal(versionedFile.literal(math.huge), false, 'nor is an infinite number')
  expect.raises(function()
    versionedFile.render({ run = function() end }, 1)
  end, 'other than a literal')
end)

test('saved settings read their entries, write them atomically, and report what they cannot read', function()
  local native = testing.native()
  native.events.files['settings.saved'] = versionedFile.render({ entries = { theme = { mode = 'light' } } }, 1)
  local saved = savedSettings.open 'settings.saved'
  expect.equal(saved.overrides.theme.mode, 'light', 'the saved entry is read')
  saved.overrides.theme.mode = 'dark'
  saved.write()
  local again = savedSettings.open 'settings.saved'
  expect.equal(again.overrides.theme.mode, 'dark', 'the write is read back')

  native.events.saveFailure = 'the disk is full'
  saved.write()
  local reports = reported(native)
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(reports[1]:find('the disk is full', 1, true), reports[1])

  native.events.files['settings.saved'] = 'return ('
  savedSettings.open 'settings.saved'
  reports = reported(native)
  expect.truthy(reports[1] and reports[1]:find('could not be read', 1, true), table.concat(reports, '\n'))
end)

test('a newer saved settings file applies nothing and is never overwritten', function()
  local native = testing.native()
  local future = 'return { version = 2, data = { entries = { theme = { mode = "light" } } } }'
  native.events.files['settings.saved'] = future
  local saved = savedSettings.open 'settings.saved'
  local reports = reported(native)
  expect.truthy(reports[1] and reports[1]:find('newer than this version reads', 1, true), table.concat(reports, '\n'))
  expect.equal(next(saved.overrides), nil, 'nothing applies')
  saved.overrides.theme = { mode = 'dark' }
  saved.write()
  expect.equal(native.events.files['settings.saved'], future, 'the newer file is kept')
end)

return test
