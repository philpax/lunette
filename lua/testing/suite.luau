-- Stores test cases in registration order for the test runner, and closes the sessions each case opens.

local suite = {}

local metatable = {}
metatable.__index = metatable

-- Sessions opened by the running case, or nil outside a case.
local opened = nil

local function closing(run)
  return function()
    opened = {}
    local ok, failure = xpcall(run, debug.traceback)
    local sessions = opened
    opened = nil
    local problems = {}
    for index = #sessions, 1, -1 do
      local closed, problem = pcall(sessions[index].close, sessions[index])
      if not closed then
        problems[#problems + 1] = 'closing a session failed: ' .. tostring(problem)
      end
    end
    if not ok then
      table.insert(problems, 1, tostring(failure))
    end
    if #problems > 0 then
      error(table.concat(problems, '\n'), 0)
    end
  end
end

function metatable:__call(name, run)
  if type(name) ~= 'string' then
    error('testing: a case is named by a string, not a ' .. type(name), 2)
  end
  if type(run) ~= 'function' then
    error("testing: the case '" .. name .. "' is not a function", 2)
  end
  self.cases[#self.cases + 1] = { name = name, run = closing(run) }
end

function suite.new()
  return setmetatable({ cases = {} }, metatable)
end

function suite.isSuite(value)
  return type(value) == 'table' and getmetatable(value) == metatable
end

-- Records a session to close after the running case. A session opened outside a case is the caller's to close.
function suite.opened(session)
  if opened then
    opened[#opened + 1] = session
  end
end

return suite
