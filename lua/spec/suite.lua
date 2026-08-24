-- A spec file's collection of named cases.
--
-- A spec file builds one, adds cases by calling it, and returns it. Cases retain
-- insertion order, so reports follow the file and setup-dependent cases stay put.
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

-- A fresh suite named for the module it covers, such as `@mullion/signal`.
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
