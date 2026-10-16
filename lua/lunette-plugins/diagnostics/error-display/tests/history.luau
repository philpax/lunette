local testing = require '@testing'
local errors = require '@lunette-contracts/errors'
local history = require '../private/history'
local expect = testing.expect
local test = testing.suite()

local sequence = 0
local function report(message: string, suppressed: number?, traceback: string?): errors.Report
  sequence += 1
  return table.freeze {
    message = message,
    traceback = traceback or 'traceback',
    suppressed = suppressed or 0,
    text = message,
    sequence = sequence,
  }
end

test('a repeat keeps its entry identity and adds its suppressed reports to both counts', function()
  local state = history.record(history.new(4), report 'a')
  state = history.record(state, report 'b')
  state = history.record(state, report('a', 2))
  expect.equal(#state.entries, 2, 'two distinct reports')
  local first = state.entries[1]
  expect.equal(first.id, 'report-1', 'the repeat keeps its id')
  expect.equal(first.count, 4)
  expect.equal(first.unseen, 4)
  expect.equal(first.sequence, sequence, 'the entry carries the latest sequence')
end)

test('a different traceback is a different report', function()
  local state = history.record(history.new(4), report 'a')
  state = history.record(state, report('a', 0, 'elsewhere'))
  expect.equal(#state.entries, 2)
end)

test('dismissal clears what is new and keeps the counts', function()
  local state = history.record(history.record(history.new(4), report 'a'), report 'a')
  state = history.dismiss(state)
  expect.equal(#history.unseen(state), 0)
  expect.equal(state.entries[1].count, 2)
  state = history.record(state, report 'a')
  expect.equal(state.entries[1].unseen, 1, 'a repeat after dismissal is new again')
  expect.equal(state.entries[1].count, 3)
end)

test('the least recent entry leaves a full history, and ids are never reused', function()
  local state = history.new(2)
  for _, message in { 'a', 'b', 'c' } do
    state = history.record(state, report(message))
  end
  expect.equal(#state.entries, 2)
  expect.equal(state.entries[2].message, 'b', 'the oldest report left')
  state = history.record(state, report 'a')
  expect.equal(state.entries[1].id, 'report-4', 'a forgotten report returns as a new entry')
end)

test('a page clamps its index and describes an empty list', function()
  local empty = history.page({}, 3, 2)
  expect.equal(empty.total, 0)
  expect.equal(empty.index, 1)
  expect.equal(empty.pages, 1)
  expect.truthy(empty.first > empty.last, 'an empty page shows no range')
  local state = history.new(10)
  for _, message in { 'a', 'b', 'c' } do
    state = history.record(state, report(message))
  end
  local last = history.page(state.entries, 9, 2)
  expect.equal(last.index, 2, 'a page past the end clamps to the last')
  expect.equal(#last.entries, 1)
  expect.equal(last.entries[1].message, 'a')
  expect.equal(history.page(state.entries, 0, 2).index, 1, 'a page before the start clamps to the first')
end)

return test
