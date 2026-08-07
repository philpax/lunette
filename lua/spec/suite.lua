-- A spec file's collection of named cases.
--
-- A spec file builds one of these, adds its cases by calling it, and returns
-- it. Cases keep the order they were added in, so a failure report reads in the
-- order the file does, and so a case that depends on the collector having been
-- exercised earlier is not reordered away from it.
--
-- This is not a test framework. It holds a name, an ordered list, and nothing
-- else; the running and the reporting are `spec.runner`'s, and the assertions
-- are `spec.expect`'s.

local suite = {}

local metatable = {}
metatable.__index = metatable

-- Adds a case. `suite('name', function() ... end)`, so a spec file reads as a
-- list of sentences rather than as a list of table constructors.
function metatable:__call(name, run)
  if type(name) ~= 'string' then
    error('spec: a case is named by a string, not a ' .. type(name), 2)
  end
  if type(run) ~= 'function' then
    error("spec: the case '" .. name .. "' is not a function", 2)
  end
  self.cases[#self.cases + 1] = { name = name, run = run }
end

-- A fresh suite named for the module it covers, such as `mullion.signal`.
function suite.new(name)
  if type(name) ~= 'string' then
    error('spec: a suite is named by a string, not a ' .. type(name), 2)
  end
  return setmetatable({ name = name, cases = {} }, metatable)
end

-- Whether `value` is one of these, which is what `spec.runner` checks a
-- required spec file returned.
function suite.isSuite(value)
  return type(value) == 'table' and getmetatable(value) == metatable
end

return suite
