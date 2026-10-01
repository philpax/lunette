-- A spec file's collection of named cases.
--
-- A spec file builds one of these, adds its cases by calling it,
-- and returns it. Cases keep the order in which the spec file adds them. A failure report
-- lists them in that order, and a case that depends on an earlier added case runs after it.
--
-- It is not a test framework. It holds a name and an ordered list;
-- the running and the reporting are `spec.runner`'s, and the assertions are `spec.expect`'s.

local suite = {}

local metatable = {}
metatable.__index = metatable

-- Adds a case. The call form `suite('name', function() ... end)` keeps each case
-- on one line. A spec file then appears as a list of sentences.
function metatable:__call(name, run)
  if type(name) ~= 'string' then
    error('spec: a case is named by a string, not a ' .. type(name), 2)
  end
  if type(run) ~= 'function' then
    error("spec: the case '" .. name .. "' is not a function", 2)
  end
  self.cases[#self.cases + 1] = { name = name, run = run }
end

-- A new suite named for the module it covers, such as
-- `lunette-plugins.scale.chooser`.
function suite.new(name)
  if type(name) ~= 'string' then
    error('spec: a suite is named by a string, not a ' .. type(name), 2)
  end
  return setmetatable({ name = name, cases = {} }, metatable)
end

-- Whether `value` is one of these suites. `spec.runner` requires a spec file
-- to return one and checks the returned value with this predicate.
function suite.isSuite(value)
  return type(value) == 'table' and getmetatable(value) == metatable
end

return suite
