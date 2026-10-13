-- Owner-scoped readers share one immutable publication per source and frame.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/audio'
local frame = require '@lunette-contracts/frame'
local config = require '@lunette-plugins/audio/config'

export type Config = config.Config
export type Settings = config.Settings
export type Service = contract.Service

local build: (plugin.Context, Settings) -> Service
local sourceOf: (unknown) -> contract.Source
local empty: (contract.Source, contract.State, number) -> contract.Snapshot
local publication: (contract.Source, contract.Snapshot) -> contract.Snapshot

-- This structural boundary matches the native capture without owning its lifetime.
type Capture = {
  read id: number,
  read dead: boolean,
  read snapshot: (Capture) -> contract.Snapshot,
  read close: (Capture) -> (),
}
type Shared = {
  source: contract.Source,
  capture: Capture,
  readers: number,
  closed: boolean,
  latest: contract.Snapshot,
}

local STARTING: contract.State = table.freeze { kind = 'starting' :: 'starting' }
local ENDED: contract.State = table.freeze { kind = 'ended' :: 'ended' }

build = function(context: plugin.Context, _settings: Settings): Service
  local frames = context:require(frame.capability)
  local system: Shared? = nil
  local processes: { [number]: Shared } = {}
  local validated: { [lunette.Process]: boolean } = setmetatable({}, { __mode = 'k' })
  local frameGeneration = 0

  local function find(source: contract.Source): Shared?
    return if source.kind == 'system' then system else processes[source.process.id]
  end

  local function forget(shared: Shared): ()
    if shared.source.kind == 'system' then
      system = nil
    else
      processes[shared.source.process.id] = nil
    end
  end

  local function release(shared: Shared): ()
    if shared.closed then
      return
    end
    shared.capture:close()
    shared.closed = true
    forget(shared)
  end

  local function share(source: contract.Source): Shared
    if source.kind == 'system' or validated[source.process] then
      local existing = find(source)
      if existing then
        return existing
      end
    end

    -- A distinct process handle crosses the native boundary even when its id is already shared.
    local capture: Capture = lunette.openAudio(source)
    if source.kind == 'process' then
      validated[source.process] = true
    end
    local existing = find(source)
    if existing then
      capture:close()
      return existing
    end
    local shared: Shared = {
      source = source,
      capture = capture,
      readers = 0,
      closed = false,
      latest = empty(source, STARTING, frameGeneration),
    }
    if source.kind == 'system' then
      system = shared
    else
      processes[source.process.id] = shared
    end
    return shared
  end

  local function poll(shared: Shared): ()
    if shared.closed then
      return
    end
    if shared.capture.dead then
      shared.latest = empty(shared.source, ENDED, frameGeneration)
      return
    end
    shared.latest = publication(shared.source, shared.capture:snapshot())
  end

  context:effect(function(): () -> ()
    return function(): ()
      if system then
        release(system)
      end
      for _, shared in pairs(table.clone(processes)) do
        release(shared)
      end
      table.clear(validated)
    end
  end)
  frames:onUpdate(context, {
    phase = 'input',
    order = -1000,
    run = function(_dt: number): ()
      frameGeneration += 1
      if system then
        poll(system)
      end
      for _, shared in pairs(processes) do
        poll(shared)
      end
    end,
  })

  return table.freeze {
    open = function(_self: Service, owner: plugin.Owner, given: contract.Source): contract.Reader
      context:checkOwner(owner)
      local source = sourceOf(given)
      local lifetime: plugin.Effect? = nil
      local terminal: contract.Snapshot? = nil
      local attachment: Shared? = nil
      local reader, effect = context:resource(owner, function(): (contract.Reader, () -> ())
        local shared = share(source)
        shared.readers += 1
        attachment = shared
        local made: contract.Reader = table.freeze {
          source = shared.source,
          snapshot = function(_reader: contract.Reader): contract.Snapshot
            if terminal then
              return terminal
            end
            local attached = attachment
            assert(attached ~= nil, 'audio: missing reader attachment')
            return attached.latest
          end,
          close = function(_reader: contract.Reader): ()
            local owned = lifetime
            if owned then
              owned:dispose()
            end
          end,
        }
        return made,
          function(): ()
            local attached = attachment
            if not attached then
              return
            end
            terminal = empty(attached.source, ENDED, attached.latest.frameGeneration)
            if attached.readers == 1 then
              release(attached)
            end
            attached.readers -= 1
            attachment = nil
            lifetime = nil
          end
      end)
      lifetime = effect
      return reader
    end,
    processes = function(_self: Service): { contract.ProcessStatus }
      local windows = lunette.windows()
      local labels: { [number]: { windowId: number, text: string } } = {}
      for _, window in ipairs(windows) do
        local process = window.process
        if not window.dead and process and not process.dead then
          local title = window.title or ''
          local label = if title ~= '' then title else window.appId or ''
          local selected = labels[process.id]
          if label ~= '' and (selected == nil or window.id < selected.windowId) then
            labels[process.id] = { windowId = window.id, text = label }
          end
        end
      end
      local result: { contract.ProcessStatus } = {}
      local seen: { [number]: boolean } = {}
      local function add(process: lunette.Process): ()
        if process.dead or seen[process.id] then
          return
        end
        seen[process.id] = true
        local shared = processes[process.id]
        local selected = labels[process.id]
        local label = if selected then selected.text else 'Process ' .. process.id
        result[#result + 1] = table.freeze {
          process = process,
          label = label,
          state = if shared then shared.latest.state else nil,
        }
      end
      for _, process in ipairs(lunette.processes()) do
        add(process)
      end
      for _, window in ipairs(windows) do
        if not window.dead and window.process then
          add(window.process)
        end
      end
      table.sort(result, function(a: contract.ProcessStatus, b: contract.ProcessStatus): boolean
        return a.process.id < b.process.id
      end)
      return table.freeze(result)
    end,
  }
end

sourceOf = function(given: unknown): contract.Source
  if type(given) ~= 'table' or getmetatable(given) ~= nil then
    error('audio open: source is a plain table', 3)
  end
  local raw = given :: { [unknown]: unknown }
  if raw.kind == 'system' then
    plugin.rejectUnknownFields('audio open source', given, { 'kind' }, 3)
    local source: contract.Source = { kind = 'system' }
    return table.freeze(source)
  elseif raw.kind == 'process' then
    plugin.rejectUnknownFields('audio open source', given, { 'kind', 'process' }, 3)
    if raw.process == nil then
      error('audio open: a process source requires a process handle', 3)
    end
    -- Native capture validates session membership and the exact handle type.
    local source = given :: contract.Source
    if source.kind == 'process' then
      local descriptor: contract.Source = { kind = 'process', process = source.process }
      return table.freeze(descriptor)
    end
  end
  error('audio open: source kind is system or process', 3)
end

empty = function(source: contract.Source, state: contract.State, generation: number): contract.Snapshot
  local blocks: { contract.Block } = {}
  return table.freeze { source = source, state = state, frameGeneration = generation, blocks = table.freeze(blocks) }
end

publication = function(source: contract.Source, native: contract.Snapshot): contract.Snapshot
  local blocks: { contract.Block } = {}
  for index = 1, #native.blocks do
    local block = native.blocks[index]
    blocks[#blocks + 1] = table.freeze {
      sequence = block.sequence,
      generation = block.generation,
      frameCount = block.frameCount,
      sampleRate = block.sampleRate,
      channels = block.channels,
      startFrame = block.startFrame,
      timing = block.timing,
      gap = block.gap,
      droppedFrames = block.droppedFrames,
      copySamples = function(_block: contract.Block): buffer
        return block:copySamples()
      end,
    }
  end
  return table.freeze {
    source = source,
    state = table.freeze(table.clone(native.state)),
    frameGeneration = native.frameGeneration,
    blocks = table.freeze(blocks),
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'audio',
  capability = contract.capability,
  requires = { frame.capability },
  schema = config.schema,
  build = build,
}
