local testing = require '@testing'
local lunette = require '@lunette'
local menu = require '@lunette-contracts/menu'
local picker = require('../').definition

local test = testing.suite()
local expect = testing.expect

local function boot(fake: testing.Native?): menu.Service
  local session = testing.boot({ 'menu', { id = 'window-capture', definition = picker } }, { native = fake })
  return assert(session:observe(menu.capability).service)
end

local function find(service: menu.Service, id: string): menu.Descriptor
  for _, row in service:list() do
    if row.id == 'desktop/window-capture/' .. id then
      return row
    end
  end
  error('Missing picker row ' .. id)
end

test('a host without a window picker contributes no menu rows', function()
  expect.equal(#boot():list(), 0)
end)

test('two windows can be picked, one can stop sharing, and stale rows cannot act', function()
  local fake = testing.native()
  local previousChoices, previousCapture = lunette.captureWindows, lunette.captureWindow
  local previousStop = lunette.stopCaptureWindow
  local choices: { lunette.CaptureWindow } = {
    { id = 7, title = 'Notes', captured = false },
    { id = 8, title = 'Browser', captured = false },
  }
  local picked: { number } = {}
  local stopped: { number } = {}
  lunette.captureWindows = function(): { lunette.CaptureWindow }
    return choices
  end
  local function mark(id: number, captured: boolean): ()
    for index, choice in choices do
      if choice.id == id then
        choices[index] = { id = id, title = choice.title, captured = captured }
      end
    end
  end
  lunette.captureWindow = function(id: number): boolean
    table.insert(picked, id)
    mark(id, true)
    return true
  end
  lunette.stopCaptureWindow = function(id: number): boolean
    table.insert(stopped, id)
    mark(id, false)
    return true
  end

  local service = boot(fake)
  local first = find(service, '7')
  local openedFirst = service:invoke(first.id, first.token)
  local second = find(service, '8')
  local openedSecond = service:invoke(second.id, second.token)
  choices = { { id = 7, title = 'Notes', captured = true } }
  local refresh = find(service, 'refresh')
  service:invoke(refresh.id, refresh.token)
  local stale = service:invoke(second.id, second.token)
  local refreshed = find(service, '7')
  local stop = service:invoke(refreshed.id, refreshed.token)
  local afterStop = find(service, '7')
  lunette.captureWindows, lunette.captureWindow = previousChoices, previousCapture
  lunette.stopCaptureWindow = previousStop

  expect.equal(openedFirst.kind, 'invoked')
  expect.equal(openedSecond.kind, 'invoked')
  expect.equal(stale.kind, 'unavailable')
  expect.equal(refreshed.selected, true)
  expect.equal(refreshed.label, 'Stop sharing Notes')
  expect.equal(stop.kind, 'invoked')
  expect.equal(afterStop.selected, false)
  expect.equal(afterStop.label, 'Notes')
  expect.equal(table.concat(picked, ','), '7,8')
  expect.equal(table.concat(stopped, ','), '7')
end)

return test
