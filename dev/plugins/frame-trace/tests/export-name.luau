local testing = require '@testing'
local exportName = require '../private/export-name'
local expect = testing.expect
local test = testing.suite()

local function name(timestamp: string, sequence: number): string
  return string.format('frame-trace-%s-%03d.csv', timestamp, sequence)
end

test('the first export uses a readable timestamp and sequence', function()
  expect.equal(exportName.unique('20261107-142305', {}), name('20261107-142305', 1))
end)

test('exports skip names already present in the save directory', function()
  local timestamp = '20261107-142305'
  expect.equal(
    exportName.unique(timestamp, { name(timestamp, 1), 'notes.txt', name(timestamp, 2) }),
    name(timestamp, 3)
  )
end)

test('exports reuse a gap without replacing later sequences or older filenames', function()
  local timestamp = '20261107-142305'
  local files = { 'frame-trace.csv', name('20261106-142305', 1), name(timestamp, 1), name(timestamp, 3) }
  expect.equal(exportName.unique(timestamp, files), name(timestamp, 2))
end)

test('export sequences remain unique beyond three digits', function()
  local timestamp = '20261107-142305'
  local files: { string } = {}
  for sequence = 1, 1000 do
    table.insert(files, name(timestamp, sequence))
  end
  expect.equal(exportName.unique(timestamp, files), name(timestamp, 1001))
end)

return test
