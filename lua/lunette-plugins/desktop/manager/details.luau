-- Formats copied runtime and broker records without invoking registered callbacks.

local lunette = require '@lunette'
local composition = require '@lunette-contracts/composition'
local inspection = require '@lunette-contracts/inspection'
local graph = require './graph'
local projection = require './projection'

local details = {}

export type Broker = {
  read name: string,
  read snapshot: inspection.Snapshot,
}

local function ordered(values: { read [string]: string | number | boolean }): string
  local keys: { string } = {}
  for key in values do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local result: { string } = {}
  for _, key in keys do
    result[#result + 1] = key .. '=' .. tostring(values[key])
  end
  return table.concat(result, ', ')
end

function details.entry(entries: { composition.Entry }, instanceId: string): composition.Entry?
  for _, entry in entries do
    if entry.instanceId == instanceId then
      return entry
    end
  end
  return nil
end

local function joined(values: { read [number]: string }): string
  local copy: { string } = {}
  for index, value in values do
    copy[index] = value
  end
  return table.concat(copy, ', ')
end

local function instanceLines(result: { string }, node: lunette.PluginInstanceSnapshot): ()
  result[#result + 1] = node.name .. ' (#' .. node.id .. ')'
  result[#result + 1] = 'State: ' .. node.state .. '; enabled: ' .. tostring(node.enabled)
  result[#result + 1] = 'Authority: ' .. node.authority .. '; retired: ' .. tostring(node.retired)
  result[#result + 1] = 'Activation: '
    .. (node.activationId or 'none')
    .. '; generation: '
    .. (node.generationId or 'none')
  result[#result + 1] = 'Owner: ' .. (node.parentId or 'session')
  result[#result + 1] = 'Children: ' .. (if #node.children == 0 then 'none' else joined(node.children))
  result[#result + 1] = 'Direct consumers: ' .. (if #node.dependents == 0 then 'none' else joined(node.dependents))
  for _, field in node.required do
    result[#result + 1] = 'Requires ' .. field.field .. ': ' .. field.contract.display
  end
  for _, field in node.provided do
    result[#result + 1] = 'Provides ' .. field.field .. ': ' .. field.contract.display
  end
  for _, binding in node.bindings do
    result[#result + 1] = 'Bound '
      .. binding.contract.display
      .. ' -> #'
      .. binding.providerId
      .. ', generation '
      .. binding.generationId
      .. (if binding.current then ' (current)' else ' (withdrawn)')
  end
  for _, binding in node.failedBindings do
    result[#result + 1] = 'Failed activation binding '
      .. binding.contract.display
      .. ' -> #'
      .. binding.providerId
      .. ', generation '
      .. binding.generationId
  end
  if node.diagnostic then
    result[#result + 1] = 'Diagnostic: ' .. node.diagnostic
  end
  if node.lastFailure then
    result[#result + 1] = 'Last failure: ' .. node.lastFailure
  end
  result[#result + 1] = 'Replacement pending: ' .. tostring(node.replacementRequested)
  result[#result + 1] = 'Cleanup failed: ' .. tostring(node.cleanupFailed)
  result[#result + 1] = 'Native effects: ' .. #node.effects
  for _, effect in node.effects do
    result[#result + 1] = 'Effect ' .. effect.ordinal .. ': ' .. effect.state .. '; activation ' .. effect.activationId
  end
end

function details.lines(
  projected: projection.Projected,
  selection: graph.Selection?,
  entries: { composition.Entry },
  brokers: { Broker },
  ownerId: (inspection.Registration) -> string?
): { string }
  local result: { string } = {}
  if not selection then
    result[1] = 'Select a node or relationship.'
    for _, entry in entries do
      result[#result + 1] = entry.id .. ': ' .. entry.state
    end
    return result
  end
  if selection.kind == 'edge' then
    local edge = graph.edge(projected.graph, selection.id)
    if edge then
      result[#result + 1] = edge.label
      result[#result + 1] = edge.kind .. ': #' .. edge.from .. ' -> #' .. edge.to
      local binding = projected.bindings[edge.id]
      if binding then
        result[#result + 1] = 'Provider generation: ' .. binding.generationId
        result[#result + 1] = 'Current: ' .. tostring(binding.current)
      end
    end
    return result
  end
  local node = projected.instances[selection.id]
  if not node then
    return { 'The selected instance is no longer present.' }
  end
  instanceLines(result, node)
  local entry = details.entry(entries, node.id)
  if entry then
    result[#result + 1] = 'Entry: ' .. entry.id .. '; protected: ' .. tostring(entry.protected)
    result[#result + 1] = 'Configuration: ' .. (if entry.schema then 'schema available' else 'source-defined')
    result[#result + 1] = 'Recovery: '
      .. (if entry.previousConfig ~= nil then 'previous configuration available' else 'none')
  end
  for _, broker in brokers do
    local owned: { inspection.Registration } = {}
    for _, registration in broker.snapshot.registrations do
      if ownerId(registration) == node.id then
        owned[#owned + 1] = registration
      end
    end
    if #owned > 0 then
      result[#result + 1] = broker.name .. ': ' .. #owned .. ' logical registrations'
      for _, registration in owned do
        result[#result + 1] = registration.kind
          .. ' '
          .. (registration.name or registration.source)
          .. ': '
          .. (if registration.live then 'live' else 'dead')
        local text = ordered(registration.details)
        if text ~= '' then
          result[#result + 1] = text
        end
      end
    end
    if #owned > 0 or node.name == broker.name then
      local state = ordered(broker.snapshot.state)
      if state ~= '' then
        result[#result + 1] = broker.name .. ' state: ' .. state
      end
      for _, field in broker.snapshot.unobservable do
        result[#result + 1] = 'Unavailable: ' .. field
      end
    end
  end
  return result
end

return details
