local testing = require '@testing'
local stores = require '../private/controls/stores'
local selection = require '../private/selection/selection'
local expect = testing.expect
local test = testing.suite()

local function renderer(): stores.Renderer
  return {
    enabled = function(): boolean
      return true
    end,
    setEnabled = function(_enabled: boolean): () end,
  }
end

test('published application tokens resolve during change callbacks and disappear with their rows', function()
  local native = testing.native()
  native.advanceFrame()
  local process = native.newProcess(81)
  local published = stores.new(selection.new(), renderer())
  local previous: string? = nil
  local changes = 0
  local unsubscribe = published.applications:subscribe(function(rows: { stores.Application }): ()
    changes += 1
    if previous then
      expect.equal(published.process(previous), nil, 'a removed token is already unavailable to subscribers')
    end
    for _, row in rows do
      expect.truthy(rawequal(published.process(row.token), row.process), 'lookup uses the published wrapper')
    end
  end)
  published.refresh()
  local first = published.applications:get()[1]
  expect.equal(first.process, process, 'the initial row names the process')
  previous = first.token
  table.clear(native.events.processes)
  published.refresh()
  expect.equal(#published.applications:get(), 0, 'absence removes the row')
  local replacement = native.newProcess(81)
  published.refresh()
  local next = published.applications:get()[1]
  expect.truthy(next.token ~= previous, 'a replacement with the same numeric id receives a new token')
  expect.equal(published.process(next.token), replacement, 'the replacement token names its own process')
  expect.equal(changes, 3, 'each changed list publishes once')
  unsubscribe()
end)

test('equal fresh wrappers keep the published wrapper and token without republishing unchanged rows', function()
  testing.native().advanceFrame()
  local lunette = require '@lunette'
  local identity = {}
  local equality = {
    __eq = function(left: any, right: any): boolean
      return left.identity == right.identity
    end,
  }
  lunette.processes = function(): { any }
    return { setmetatable({ id = 9007199254740991, dead = false, identity = identity }, equality) }
  end
  local published = stores.new(selection.new(), renderer())
  published.refresh()
  local first = published.applications:get()[1]
  local changes = 0
  local unsubscribe = published.applications:subscribe(function(): ()
    changes += 1
  end)
  for _ = 1, 300 do
    published.refresh()
    local row = published.applications:get()[1]
    expect.equal(row.token, first.token, 'logical equality preserves the token')
    expect.truthy(rawequal(row.process, first.process), 'logical equality preserves the retained wrapper')
    expect.truthy(rawequal(published.process(first.token), first.process), 'lookup retains no fresh wrapper')
  end
  expect.equal(changes, 0, 'fresh equal wrappers do not invalidate an unchanged list')
  unsubscribe()
end)

return test
