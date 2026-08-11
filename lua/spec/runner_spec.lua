-- Covers lua/spec/runner.lua.
--
-- The runner is what decides which specs run, so a defect in it is silent by
-- construction: a discovery that missed a directory would report every case it
-- did find as passing and say nothing about the ones it never loaded. That is
-- the one failure in this tree that no other spec can catch.
--
-- Discovery is driven against a table of strings rather than a real directory,
-- which is what `runner.discover` taking its filesystem as an argument is for.

local expect = require 'spec.expect'
local runner = require 'spec.runner'
local suite = require 'spec.suite'

local spec = suite.new 'spec.runner'

-- A filesystem over a table of `{ [path] = { items } }`, where a path with no
-- entry is a file.
local function fakeFilesystem(directories)
  return {
    list = function(path)
      local items = directories[path]
      if not items then
        error('the fake filesystem has no directory at ' .. path)
      end
      -- Copied, because `discover` sorts what it is given and a fake that
      -- handed out its own table would be reordered under it.
      local listed = {}
      for index, item in ipairs(items) do
        listed[index] = item
      end
      return listed
    end,
    isDirectory = function(path)
      return directories[path] ~= nil
    end,
  }
end

spec('discovery finds spec files and skips everything else', function()
  local filesystem = fakeFilesystem {
    ['spec'] = { 'expect.lua', 'runner.lua', 'signal_spec.lua', 'notes.txt' },
  }

  local names = runner.discover(filesystem, 'spec', 'spec.')

  expect.equal(table.concat(names, ','), 'spec.signal_spec', 'the names found')
end)

-- The defect this file exists for. A module under a new subdirectory that
-- discovery does not descend into is a whole file's worth of coverage lost with
-- no report of any kind.
spec('discovery descends into subdirectories', function()
  local filesystem = fakeFilesystem {
    ['spec'] = { 'a_spec.lua', 'nested' },
    ['spec/nested'] = { 'b_spec.lua', 'deeper' },
    ['spec/nested/deeper'] = { 'c_spec.lua' },
  }

  local names = runner.discover(filesystem, 'spec', 'spec.')

  expect.equal(table.concat(names, ','), 'spec.a_spec,spec.nested.b_spec,spec.nested.deeper.c_spec', 'the names found')
end)

spec('discovery is sorted, so a run reports in a stable order', function()
  local filesystem = fakeFilesystem {
    ['spec'] = { 'c_spec.lua', 'a_spec.lua', 'b_spec.lua' },
  }

  local names = runner.discover(filesystem, 'spec', 'spec.')

  expect.equal(table.concat(names, ','), 'spec.a_spec,spec.b_spec,spec.c_spec', 'the order')
end)

spec('discovery of an empty tree finds nothing rather than raising', function()
  local names = runner.discover(fakeFilesystem { ['spec'] = {} }, 'spec', 'spec.')

  expect.equal(#names, 0, 'the names found')
end)

-- A file under `lua/spec/` that runs nothing is coverage silently lost, so it
-- is an error rather than a skip. `spec.expect` is a module that is not a
-- suite, which is what a mis-written spec file looks like from here.
spec('a module that is not a suite is refused', function()
  expect.raises(function()
    runner.collect { 'spec.expect' }
  end, 'did not return a spec suite', 'collect')
end)

spec('every case runs even when one of them raises', function()
  local ran = {}
  local collected = suite.new 'a suite'
  collected('first', function()
    ran[#ran + 1] = 'first'
  end)
  collected('second', function()
    error 'this one fails'
  end)
  collected('third', function()
    ran[#ran + 1] = 'third'
  end)

  local results = runner.run { collected }

  expect.equal(table.concat(ran, ','), 'first,third', 'the cases that ran')
  expect.equal(results.total, 3, 'cases counted')
  expect.equal(#results.failures, 1, 'failures')
  expect.equal(results.failures[1].case, 'second', 'the failing case')
  expect.truthy(
    results.failures[1].message:find('this one fails', 1, true),
    'the failure should carry the message it raised'
  )
end)

spec('the finished hook runs once per case', function()
  local finished = 0
  local collected = suite.new 'a suite'
  collected('first', function() end)
  collected('second', function()
    error 'this one fails'
  end)

  runner.run({ collected }, function()
    finished = finished + 1
  end)

  expect.equal(finished, 2, 'hook calls')
end)

spec('a run with no failures is reported as such', function()
  local collected = suite.new 'a suite'
  collected('a case', function() end)

  local report = runner.format(runner.run { collected })

  expect.equal(report, '1 case, 0 failures', 'the report')
end)

spec('a failure is named in the report', function()
  local collected = suite.new 'a suite'
  collected('a case', function()
    error 'nope'
  end)

  local report = runner.format(runner.run { collected })

  expect.truthy(report:find('FAIL a suite: a case', 1, true), 'the report should name the case')
  expect.truthy(report:find('1 case, 1 failure', 1, true), 'the report should count it')
end)

return spec
