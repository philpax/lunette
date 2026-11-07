local testing = require '@testing'
local native = require '@lunette'
local menu = require '@lunette-contracts/menu'
local expect = testing.expect
local test = testing.suite()

type SavedFile = { directory: string, name: string, contents: string }

test('the development menu owns public observation and exports only after capture ends', function()
  local callback: ((native.FrameTiming) -> ())? = nil
  local cancelled = 0
  local saved: SavedFile? = nil
  local files: { string } = {}
  native.observeFrameTiming = function(run: (native.FrameTiming) -> ()): () -> ()
    callback = run
    return function(): ()
      callback = nil
      cancelled += 1
    end
  end
  native.saveFile = function(directory: string, name: string, contents: string): ()
    expect.equal(callback, nil, 'export never runs during observation')
    saved = { directory = directory, name = name, contents = contents }
    table.insert(files, name)
  end
  lovr.filesystem = {
    getSaveDirectory = function(): string
      return '/trace-fixture'
    end,
    getDirectoryItems = function(_path: string): { string }
      return table.clone(files)
    end,
  }
  local state = testing.start {
    { id = 'test/menu', definition = require('@lunette-plugins/menu/action-registry').definition },
    { id = 'dev/frame-trace', definition = require('../init').definition, config = { capacity = 1 } },
  }
  local menus = assert(state:observe(menu.capability).service)
  expect.equal(callback, nil, 'composition is idle')
  expect.equal(menus:invoke('dev/frame-trace/export').kind, 'unavailable')
  expect.equal(menus:invoke('dev/frame-trace/start').kind, 'invoked')
  expect.equal(menus:invoke('dev/frame-trace/start').kind, 'unavailable')
  assert(callback) {
    sequence = 12,
    syncTime = 1,
    interval = 0.022,
    update = 0.001,
    focused = false,
    executionMode = 'interpreter',
    foveation = 'low,custom',
    gcSteps = 1,
  }
  expect.equal(cancelled, 1)
  expect.equal(menus:invoke('dev/frame-trace/export').kind, 'invoked')
  local first = assert(saved)
  expect.truthy(first.name:match '^frame%-trace%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d%d%d+%.csv$')
  expect.truthy(first.contents:find('formatVersion,sequence,syncTime,sync,interval', 1, true))
  expect.equal(menus:invoke('dev/frame-trace/export').kind, 'invoked')
  local second = assert(saved)
  expect.truthy(first.name ~= second.name, 'a repeated export does not overwrite the first')
  expect.equal(second.directory, first.directory)
  expect.truthy(second.contents:find('formatVersion,sequence,syncTime,sync,interval', 1, true))
  expect.truthy(second.contents:find('1,12,1,,0.022,0.001', 1, true))
  expect.truthy(second.contents:find('"low,custom",interpreter', 1, true), 'public wire quotes metadata')
  expect.equal(menus:invoke('dev/frame-trace/cancel').kind, 'invoked')
  expect.equal(menus:invoke('dev/frame-trace/export').kind, 'unavailable')
  expect.equal(menus:invoke('dev/frame-trace/start').kind, 'invoked')
  state:close()
  expect.equal(cancelled, 2, 'runtime shutdown retires observation')
end)

return test
