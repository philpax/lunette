-- Covers lua/mullion/error/panel.lua.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local errors = require 'mullion.error'
local panel = require 'mullion.error.panel'
local teardown = require 'mullion.teardown'

local spec = suite.new 'mullion.error.panel'

-- An uninstalled panel with nothing showing, and a captured report sink so that
-- a case driving the handler does not write to stderr.
local function fresh()
  panel.uninstall()
  panel.clear()
  errors.uninstall()
  errors.forget()

  local reports = {}
  errors.report = function(message)
    reports[#reports + 1] = message
  end
  return reports
end

-- A `Pass` that records what it was asked to draw. The panel reaches for four
-- methods and nothing else, which is what makes standing in for one four lines.
local function recordingPass()
  local pass = { planes = 0, texts = {}, colors = {} }
  function pass:plane()
    self.planes = self.planes + 1
  end
  function pass:text(text)
    self.texts[#self.texts + 1] = text
  end
  function pass:setColor(...)
    self.colors[#self.colors + 1] = { ... }
  end
  return pass
end

-- Everything the pass was asked to draw, joined, for a case asserting that
-- something reached the panel rather than where on it.
local function drawnText(pass)
  return table.concat(pass.texts, '\n')
end

spec('shows nothing before anything has been reported', function()
  fresh()

  expect.equal(#panel.lines(), 0, 'lines')
  expect.falsy(panel.draw(recordingPass()), 'draw')
end)

spec('an error reported through the handler reaches the panel', function()
  fresh()
  panel.install()

  errors.handle('it broke', 'a traceback', 0)

  expect.truthy(panel.current(), 'the current report')
  expect.truthy(panel.current():find('it broke'), 'the message: ' .. tostring(panel.current()))
  expect.equal(panel.count(), 1, 'the count')

  panel.uninstall()
end)

spec('the previous report sink still runs', function()
  local reports = fresh()
  panel.install()

  errors.handle('it broke', 'a traceback', 0)

  -- The log keeps everything the panel summarises, which is what makes the
  -- panel a summary rather than the only record.
  expect.equal(#reports, 1, 'report count')

  panel.uninstall()
end)

spec('a rate-limited error updates the panel once, not once per frame', function()
  fresh()
  panel.install()

  -- One frame's worth of a defect raised every frame, at 90 Hz.
  for frame = 1, 90 do
    errors.handle('it broke', 'a traceback', frame / 90)
  end

  expect.equal(panel.count(), 1, 'the count')

  panel.uninstall()
end)

spec('a second distinct error replaces the first and counts', function()
  fresh()
  panel.install()

  errors.handle('the first', 'a traceback', 0)
  errors.handle('the second', 'a traceback', 0)

  expect.equal(panel.count(), 2, 'the count')
  expect.truthy(panel.current():find('the second'), 'the current report')

  panel.uninstall()
end)

spec('draws a fill and the report over it', function()
  fresh()
  panel.show 'it broke'

  local pass = recordingPass()
  expect.truthy(panel.draw(pass), 'draw')
  expect.equal(pass.planes, 1, 'the fill')
  expect.truthy(drawnText(pass):find('it broke'), 'the report: ' .. drawnText(pass))
  expect.truthy(drawnText(pass):find('lunette'), 'the heading: ' .. drawnText(pass))
end)

spec('the heading says how many reports there have been', function()
  fresh()
  panel.show 'the first'
  panel.show 'the second'

  expect.truthy(panel.lines()[1]:find('2 so far'), 'the heading: ' .. panel.lines()[1])
end)

spec('a long report is wrapped rather than run off the panel', function()
  fresh()
  panel.show(string.rep('a', panel.COLUMNS * 3))

  for index, line in ipairs(panel.lines()) do
    expect.truthy(#line <= panel.COLUMNS, 'line ' .. index .. ' is ' .. #line .. ' characters')
  end
end)

spec('a report longer than the panel is truncated with an ellipsis', function()
  fresh()
  panel.show(string.rep('a\n', panel.LINES * 3))

  local lines = panel.lines()
  expect.truthy(#lines <= panel.LINES + 1, 'line count: ' .. #lines)
  expect.equal(lines[#lines], '…', 'the last line')
end)

spec('wrapping breaks between words when it can', function()
  fresh()
  local words = {}
  for _ = 1, 20 do
    words[#words + 1] = 'word'
  end
  panel.show(table.concat(words, ' '))

  -- Every line but the heading is whole words, which is what "breaks between
  -- words" means from outside the wrapper.
  local lines = panel.lines()
  for index = 2, #lines do
    if lines[index] ~= '…' then
      expect.falsy(lines[index]:find('^ '), 'line ' .. index .. ' starts with a space')
      expect.truthy(lines[index]:match('^[word ]*$'), 'line ' .. index .. ': ' .. lines[index])
    end
  end
end)

spec('clearing stops it showing anything', function()
  fresh()
  panel.show 'it broke'

  panel.clear()

  expect.falsy(panel.current(), 'the current report')
  expect.equal(panel.count(), 0, 'the count')
end)

spec('installing twice does nothing the second time', function()
  fresh()

  expect.truthy(panel.install(), 'the first install')
  expect.falsy(panel.install(), 'the second install')

  panel.uninstall()
end)

spec('uninstall puts the report sink back', function()
  fresh()
  local sink = errors.report

  panel.install()
  expect.falsy(errors.report == sink, 'errors.report while installed')
  expect.truthy(panel.uninstall(), 'uninstall')
  expect.equal(errors.report, sink, 'errors.report after uninstall')
  expect.falsy(panel.isInstalled(), 'isInstalled')
end)

spec('install registers a teardown hook that uninstalls', function()
  fresh()
  local sink = errors.report

  panel.install()
  local found = false
  for _, name in ipairs(teardown.pending()) do
    if name == 'mullion.error.panel' then
      found = true
    end
  end
  expect.truthy(found, 'the registered hook')

  teardown.run()
  expect.falsy(panel.isInstalled(), 'isInstalled after teardown')
  expect.equal(errors.report, sink, 'errors.report after teardown')
end)

spec('requiring twice returns the same module', function()
  expect.equal(require 'mullion.error.panel', panel, 'the module')
end)

return spec
