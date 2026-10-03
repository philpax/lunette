-- A test file's ordered list of named cases.
--
-- A test file makes one with `testing.suite()`, adds its cases by calling it, and returns it. Cases keep the
-- order the file adds them in: the runner runs them in that order, so a case that depends on an earlier one
-- runs after it, and the failure report lists them in that order.
--
-- It is not a test framework. It holds an ordered list; the running and the reporting are the runner's, in
-- `crates/lunette/tests/lua/`, and the assertions are `@testing/expect`'s.

local suite = {}

local metatable = {}
metatable.__index = metatable

-- Adds a case. The call form `test('name', function() ... end)` keeps each case on one line, so a test file
-- reads as a list of sentences.
function metatable:__call(name, run)
  if type(name) ~= 'string' then
    error('testing: a case is named by a string, not a ' .. type(name), 2)
  end
  if type(run) ~= 'function' then
    error("testing: the case '" .. name .. "' is not a function", 2)
  end
  self.cases[#self.cases + 1] = { name = name, run = run }
end

-- A new, empty suite. The runner names it by the file's path.
function suite.new()
  return setmetatable({ cases = {} }, metatable)
end

-- Whether `value` is one of these suites. The runner requires a test file to return one.
function suite.isSuite(value)
  return type(value) == 'table' and getmetatable(value) == metatable
end

return suite
