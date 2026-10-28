-- Validates each draw result before collecting preparatory passes for one draw invocation.
local contract = require '@lunette-contracts/frame'
local plugin = require '@lunette-plugin'
local protected = require '@lunette-plugins/diagnostics/protected-call'

local drawPasses = {}

export type Run = contract.DrawRun
export type Entry = {
  read owner: contract.Owner,
  read run: Run,
  read active: boolean,
}

local validate: (unknown, Pass, { [Pass]: boolean }) -> { Pass }?

function drawPasses.dispatch(context: plugin.Context, entries: { read [number]: Entry }, main: Pass): { Pass }?
  local collected: { Pass }? = nil
  local seen: { [Pass]: boolean } = {}
  local snapshot = table.clone(entries)
  for index = 1, #snapshot do
    local entry = snapshot[index]
    if entry.active and context:owns(entry.owner) then
      local result: { Pass }? = nil
      local ok = protected.call('lovr.draw', function(): ()
        result = validate((entry.run :: (Pass) -> contract.DrawPasses?)(main), main, seen)
      end)
      if ok and result and #result > 0 then
        local target: { Pass } = collected or {}
        for _, pass in ipairs(result) do
          target[#target + 1] = pass
          seen[pass] = true
        end
        collected = target
      end
    end
  end
  return collected
end

validate = function(value: unknown, main: Pass, seen: { [Pass]: boolean }): { Pass }?
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' or getmetatable(value) ~= nil then
    error('frame onDraw: the result is a plain dense array of Pass objects or nil', 0)
  end
  local raw = value :: { [unknown]: unknown }
  local length = 0
  for key in pairs(raw) do
    length += 1
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then
      error('frame onDraw: the result is a dense array indexed from 1 without other fields', 0)
    end
  end
  local result: { Pass } = {}
  local localSeen: { [Pass]: boolean } = {}
  for index = 1, length do
    local candidate = raw[index]
    if candidate == nil then
      error('frame onDraw: the result is a dense array indexed from 1 without holes', 0)
    end
    if candidate == main then
      error('frame onDraw: result[' .. index .. '] is the main draw Pass', 0)
    end
    if type(candidate) ~= 'userdata' or (candidate :: Pass):type() ~= 'Pass' then
      error('frame onDraw: result[' .. index .. '] is a Pass object', 0)
    end
    local pass = candidate :: Pass
    if seen[pass] or localSeen[pass] then
      error('frame onDraw: result[' .. index .. '] already appears in this draw invocation', 0)
    end
    localSeen[pass] = true
    result[index] = pass
  end
  return result
end

return drawPasses
