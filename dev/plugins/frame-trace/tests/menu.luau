local testing = require '@testing'
local native = require '@lunette'
local menu = require '@lunette-contracts/menu'
local expect = testing.expect
local test = testing.suite()

type SavedFile = { directory: string, name: string, contents: string }
type Fixture = {
  menus: menu.Service,
  emit: (native.FrameTiming) -> (),
  observed: () -> boolean,
  cancelled: () -> number,
  saves: { SavedFile },
  errors: { string },
  failSave: (boolean) -> (),
  close: () -> (),
}

local function fixture(capacity: number?): Fixture
  local callback: ((native.FrameTiming) -> ())? = nil
  local cancelled = 0
  local saves: { SavedFile } = {}
  local files: { string } = {}
  local saveFails = false
  local errors: { string } = {}
  native.reportError = function(report: native.ErrorReport): ()
    table.insert(errors, report.message)
  end
  native.observeFrameTiming = function(run: (native.FrameTiming) -> ()): () -> ()
    callback = run
    return function(): ()
      callback = nil
      cancelled += 1
    end
  end
  native.saveFile = function(directory: string, name: string, contents: string): ()
    expect.equal(callback, nil, 'export never runs during observation')
    assert(not saveFails, 'save unavailable')
    table.insert(saves, { directory = directory, name = name, contents = contents })
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
    { id = 'dev/frame-trace', definition = require('../init').definition, config = { capacity = capacity or 4 } },
  }
  return {
    menus = assert(state:observe(menu.capability).service),
    emit = function(row: native.FrameTiming): ()
      assert(callback)(row)
    end,
    observed = function(): boolean
      return callback ~= nil
    end,
    cancelled = function(): number
      return cancelled
    end,
    saves = saves,
    errors = errors,
    failSave = function(failed: boolean): ()
      saveFails = failed
    end,
    close = function(): ()
      state:close()
    end,
  }
end

local function action(fixture: Fixture): menu.Descriptor
  local actions = fixture.menus:list()
  expect.equal(#actions, 1, 'frame trace has exactly one action')
  local action = actions[1]
  expect.equal(action.id, 'dev/frame-trace/toggle')
  expect.equal(action.label, 'Frame trace')
  expect.equal(action.group, 'Development')
  expect.equal(action.enabled, true)
  return action
end

local function toggle(fixture: Fixture): menu.Result
  return fixture.menus:invoke(action(fixture).id)
end

test('one selected menu toggle starts capture and exports immediately when stopped', function()
  local fixture = fixture()
  expect.equal(fixture.observed(), false, 'composition is idle')
  expect.equal(action(fixture).selected, false)
  for _, removed in { 'start', 'stop', 'export', 'cancel' } do
    expect.equal(fixture.menus:invoke('dev/frame-trace/' .. removed).kind, 'unavailable')
  end
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.equal(action(fixture).selected, true)
  fixture.emit {
    sequence = 12,
    syncTime = 1,
    interval = 0.022,
    update = 0.001,
    focused = false,
    executionMode = 'interpreter',
    foveation = 'low,custom',
    gcSteps = 1,
  }
  expect.equal(#fixture.saves, 0)
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.equal(fixture.cancelled(), 1)
  expect.equal(action(fixture).selected, false)
  local first = fixture.saves[1]
  expect.truthy(first.name:match '^frame%-trace%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d%d%d+%.csv$')
  expect.truthy(first.contents:find('formatVersion,sequence,syncTime,sync,interval', 1, true))
  expect.truthy(first.contents:find('1,12,1,,0.022,0.001', 1, true))
  expect.truthy(first.contents:find('"low,custom",interpreter', 1, true), 'public wire quotes metadata')
  expect.equal(toggle(fixture).kind, 'invoked')
  fixture.emit { sequence = 13, syncTime = 2 }
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.equal(#fixture.saves, 2)
  expect.truthy(first.name ~= fixture.saves[2].name, 'a later capture does not overwrite the first')
  expect.equal(toggle(fixture).kind, 'invoked')
  fixture.close()
  expect.equal(fixture.cancelled(), 3, 'runtime shutdown retires unfinished observation')
  expect.equal(#fixture.saves, 2, 'shutdown does not export an unfinished capture')
end)

test('automatic completion exports and clears the selected toggle without another action', function()
  local fixture = fixture(1)
  expect.equal(toggle(fixture).kind, 'invoked')
  fixture.emit { sequence = 1, syncTime = 0 }
  expect.equal(fixture.cancelled(), 1)
  expect.equal(#fixture.saves, 1)
  expect.equal(action(fixture).selected, false)
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.equal(action(fixture).selected, true)
  fixture.close()
end)

test('a save failure clears capture selection and the next activation retries its rows', function()
  local fixture = fixture()
  expect.equal(toggle(fixture).kind, 'invoked')
  fixture.emit { sequence = 5, syncTime = 2 }
  fixture.failSave(true)
  expect.equal(toggle(fixture).kind, 'failed')
  expect.equal(#fixture.errors, 1)
  expect.truthy(fixture.errors[1]:find('save unavailable', 1, true))
  expect.equal(fixture.observed(), false)
  expect.equal(action(fixture).selected, false)
  expect.equal(#fixture.saves, 0)
  fixture.failSave(false)
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.equal(fixture.observed(), false, 'retry exports without starting another capture')
  expect.truthy(fixture.saves[1].contents:find('1,5,2', 1, true))
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.equal(action(fixture).selected, true)
  fixture.close()
end)

test('a malformed record clears the selected toggle before propagating the error', function()
  local fixture = fixture()
  expect.equal(toggle(fixture).kind, 'invoked')
  expect.raises(function()
    fixture.emit { sequence = 1, syncTime = 0, draw = math.huge }
  end, 'draw')
  expect.equal(fixture.cancelled(), 1)
  expect.equal(action(fixture).selected, false)
  expect.equal(#fixture.saves, 0)
  expect.equal(toggle(fixture).kind, 'invoked')
  fixture.close()
end)

return test
