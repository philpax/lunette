-- Stores test cases in registration order for the test runner.

local suite = {}

local metatable = {}
metatable.__index = metatable

function metatable:__call(name, run)
  if type(name) ~= 'string' then
    error('testing: a case is named by a string, not a ' .. type(name), 2)
  end
  if type(run) ~= 'function' then
    error("testing: the case '" .. name .. "' is not a function", 2)
  end
  self.cases[#self.cases + 1] = { name = name, run = run }
end

function suite.new()
  return setmetatable({ cases = {} }, metatable)
end

function suite.isSuite(value)
  return type(value) == 'table' and getmetatable(value) == metatable
end

return suite
