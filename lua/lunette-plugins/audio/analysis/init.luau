-- Profiles share sample-time analysis and immutable publications without depending on a visual consumer.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/audio-analysis'
local audio = require '@lunette-contracts/audio'
local frame = require '@lunette-contracts/frame'
local config = require '@self/config'
local features = require '@self/private/features'

export type Config = config.Config
export type Settings = config.Settings
export type Service = contract.Service

local build: (plugin.Context, Settings) -> Service
local resolveOptions: (unknown) -> (contract.Profile?, string?)
local sourceOf: (unknown) -> audio.Source
local snapshot: (audio.Source, contract.Profile, audio.State, number, number?, number?) -> contract.Snapshot
local steady: (features.Hop) -> contract.Steady

local ENDED: audio.State = table.freeze { kind = 'ended' :: 'ended' }

type Profile = {
  options: contract.Profile,
  analyzer: features.Analyzer,
  readers: number,
  closed: boolean,
  publication: contract.Snapshot,
  frameGeneration: number?,
  batch: features.Batch?,
  streamGeneration: number?,
  endFrame: number?,
}
type Shared = {
  source: audio.Source,
  raw: audio.Reader,
  profiles: { Profile },
  closed: boolean,
  frameGeneration: number,
  streamGeneration: number?,
  sequence: number?,
  state: audio.State,
}

build = function(context: plugin.Context, _settings: Settings): Service
  local rawAudio = context:require(audio.capability)
  local frames = context:require(frame.capability)
  local sources: { Shared } = {}
  local profileCount = 0
  local validated: { [lunette.Process]: boolean } = setmetatable({}, { __mode = 'k' })

  local function find(source: audio.Source): Shared?
    for _, shared in sources do
      if source.kind == 'system' and shared.source.kind == 'system' then
        return shared
      elseif
        source.kind == 'process'
        and shared.source.kind == 'process'
        and source.process.id == shared.source.process.id
      then
        return shared
      end
    end
    return nil
  end

  local function releaseProfile(shared: Shared, profile: Profile): ()
    if profile.closed then
      return
    end
    profile.closed = true
    profileCount -= 1
    local index = table.find(shared.profiles, profile)
    if index then
      table.remove(shared.profiles, index)
    end
    if #shared.profiles == 0 and not shared.closed then
      shared.raw:close()
      shared.closed = true
      local sourceIndex = table.find(sources, shared)
      if sourceIndex then
        table.remove(sources, sourceIndex)
      end
    end
  end

  local function share(source: audio.Source): Shared
    local found = find(source)
    if found and (source.kind == 'system' or validated[source.process]) then
      return found
    end
    -- A new process handle crosses the raw provider's native validation before sharing by logical id.
    local raw = rawAudio:open(context, source)
    if source.kind == 'process' then
      validated[source.process] = true
    end
    if found then
      raw:close()
      return found
    end
    local initial = raw:snapshot()
    local shared: Shared = {
      source = raw.source,
      raw = raw,
      profiles = {},
      closed = false,
      frameGeneration = initial.frameGeneration,
      streamGeneration = nil,
      sequence = nil,
      state = table.freeze(table.clone(initial.state)),
    }
    sources[#sources + 1] = shared
    return shared
  end

  local function poll(shared: Shared): ()
    local native = shared.raw:snapshot()
    local pending: { Profile } = {}
    for _, profile in shared.profiles do
      if profile.frameGeneration ~= native.frameGeneration then
        profile.frameGeneration = native.frameGeneration
        profile.batch = profile.analyzer:beginFrame()
        pending[#pending + 1] = profile
      end
    end
    if #pending == 0 then
      return
    end
    local nativeDropped = 0
    local state = table.freeze(table.clone(native.state))
    local stateGap = state.kind ~= 'active' and shared.state.kind == 'active'
    if state.kind ~= 'active' then
      for _, profile in pending do
        profile.analyzer:reset()
      end
    else
      for _, block in native.blocks do
        assert(block.sampleRate == 48000 and block.channels == 2, 'audio analysis: expected 48000 Hz stereo PCM')
        local newer = shared.streamGeneration == nil
          or block.generation > shared.streamGeneration
          or (
            block.generation == shared.streamGeneration and (shared.sequence == nil or block.sequence > shared.sequence)
          )
        if newer then
          local pcm = block:copySamples()
          shared.streamGeneration, shared.sequence = block.generation, block.sequence
          nativeDropped += block.droppedFrames
          for _, profile in pending do
            profile.streamGeneration = block.generation
            profile.analyzer:feed(pcm, block)
            profile.endFrame = block.startFrame + block.frameCount
          end
        end
      end
    end
    shared.frameGeneration = native.frameGeneration
    shared.state = state
    for _, profile in pending do
      local batch = profile.batch
      assert(batch ~= nil, 'audio analysis: missing frame batch')
      local hops = table.freeze(table.clone(batch.hops))
      local latest: contract.Steady? = nil
      local fresh = batch.latest
      if fresh then
        latest = steady(fresh)
      elseif not batch.gap and state.kind == 'active' then
        latest = profile.publication.latest
      end
      local gap = batch.gap or stateGap
      local reason: contract.GapReason? = if batch.gap then batch.gapReason elseif stateGap then 'state' else nil
      profile.publication = table.freeze {
        source = shared.source,
        profile = profile.options,
        state = state,
        frameGeneration = native.frameGeneration,
        generation = profile.streamGeneration,
        endFrame = profile.endFrame,
        gap = gap,
        gapReason = reason,
        droppedFrames = nativeDropped + batch.droppedFrames,
        hops = hops,
        latest = latest,
      }
      profile.batch = nil
    end
  end

  context:effect(function(): () -> ()
    return function(): ()
      for _, shared in table.clone(sources) do
        for _, profile in table.clone(shared.profiles) do
          releaseProfile(shared, profile)
        end
      end
      table.clear(validated)
    end
  end)
  frames:onUpdate(context, {
    phase = 'input',
    order = -900,
    run = function(_dt: number): ()
      for _, shared in sources do
        poll(shared)
      end
    end,
  })

  return table.freeze {
    open = function(
      _self: Service,
      owner: plugin.Owner,
      given: audio.Source,
      options: contract.Options?
    ): contract.OpenResult
      context:checkOwner(owner)
      local resolved, detail = resolveOptions(options)
      if not resolved then
        return table.freeze {
          kind = 'invalid-options' :: 'invalid-options',
          detail = detail or 'invalid profile options',
        }
      end
      local source = sourceOf(given)
      local existing = find(source)
      local match: Profile? = nil
      if existing then
        for _, profile in existing.profiles do
          if profile.options.size == resolved.size and profile.options.hop == resolved.hop then
            match = profile
            break
          end
        end
      end
      if not match and (profileCount >= 8 or (existing ~= nil and #existing.profiles >= 2)) then
        return table.freeze {
          kind = 'capacity-exceeded' :: 'capacity-exceeded',
          detail = if profileCount >= 8
            then 'eight analysis profiles are already open'
            else 'two analysis profiles are already open for this source',
        }
      end
      local lifetime: plugin.Effect? = nil
      local terminal: contract.Snapshot? = nil
      local attachment: { shared: Shared, profile: Profile }? = nil
      local reader, effect = context:resource(owner, function(): (contract.Reader, () -> ())
        local analyzer: features.Analyzer? = if match == nil then features.new(resolved) else nil
        local shared = share(source)
        local selected: Profile? = match
        if not selected then
          assert(analyzer ~= nil, 'audio analysis: missing acquired analyzer')
          local made: Profile = {
            options = resolved,
            analyzer = analyzer,
            readers = 0,
            closed = false,
            publication = snapshot(shared.source, resolved, shared.state, shared.frameGeneration, nil, nil),
            frameGeneration = if shared.state.kind ~= 'starting' or shared.frameGeneration > 0
              then shared.frameGeneration
              else nil,
            batch = nil,
            streamGeneration = shared.streamGeneration,
            endFrame = nil,
          }
          profileCount += 1
          shared.profiles[#shared.profiles + 1] = made
          selected = made
        end
        assert(selected ~= nil, 'audio analysis: missing acquired profile')
        local profile: Profile = selected
        profile.readers += 1
        attachment = { shared = shared, profile = profile }
        local made: contract.Reader = table.freeze {
          source = shared.source,
          profile = profile.options,
          snapshot = function(_reader: contract.Reader): contract.Snapshot
            if terminal then
              return terminal
            end
            local attached = attachment
            assert(attached ~= nil, 'audio analysis: missing reader attachment')
            return attached.profile.publication
          end,
          close = function(_reader: contract.Reader): ()
            if lifetime then
              lifetime:dispose()
            end
          end,
        }
        return made,
          function(): ()
            local attached = attachment
            if not attached then
              return
            end
            local held = attached.profile
            local latest = held.publication
            terminal = snapshot(
              attached.shared.source,
              held.options,
              ENDED,
              latest.frameGeneration,
              latest.generation,
              latest.endFrame
            )
            held.readers -= 1
            if held.readers == 0 then
              releaseProfile(attached.shared, held)
            end
            attachment = nil
            lifetime = nil
          end
      end)
      lifetime = effect
      return table.freeze { kind = 'success' :: 'success', reader = reader }
    end,
  }
end

resolveOptions = function(given: unknown): (contract.Profile?, string?)
  if given ~= nil and (type(given) ~= 'table' or getmetatable(given) ~= nil) then
    return nil, 'profile options are a plain table'
  end
  local raw = (given or {}) :: { [unknown]: unknown }
  for key in raw do
    if key ~= 'size' and key ~= 'hop' then
      return nil, 'profile options contain only size and hop'
    end
  end
  local size = if raw.size == nil then 2048 else raw.size
  if size ~= 512 and size ~= 1024 and size ~= 2048 then
    return nil, 'size is 512, 1024, or 2048'
  end
  local numericSize = size :: number
  local hop = if raw.hop == nil then numericSize / 4 else raw.hop
  if hop ~= numericSize / 4 and hop ~= numericSize / 2 then
    return nil, 'hop is a quarter or half of size'
  end
  return table.freeze { size = numericSize, hop = hop :: number }, nil
end

sourceOf = function(given: unknown): audio.Source
  if type(given) ~= 'table' or getmetatable(given) ~= nil then
    error('audio analysis open: source is a plain table', 3)
  end
  local raw = given :: { [unknown]: unknown }
  if raw.kind == 'system' then
    plugin.rejectUnknownFields('audio analysis source', given, { 'kind' }, 3)
    return table.freeze { kind = 'system' :: 'system' }
  elseif raw.kind == 'process' then
    plugin.rejectUnknownFields('audio analysis source', given, { 'kind', 'process' }, 3)
    if raw.process == nil or type(raw.process) == 'number' then
      error('audio analysis open: a process source requires a logical process handle', 3)
    end
    local source = given :: audio.Source
    assert(source.kind == 'process', 'audio analysis open: invalid process source')
    return table.freeze { kind = 'process' :: 'process', process = source.process }
  end
  error('audio analysis open: source kind is system or process', 3)
end

snapshot = function(
  source: audio.Source,
  profile: contract.Profile,
  state: audio.State,
  frameGeneration: number,
  generation: number?,
  endFrame: number?
): contract.Snapshot
  local hops: { contract.Hop } = {}
  return table.freeze {
    source = source,
    profile = profile,
    state = state,
    frameGeneration = frameGeneration,
    generation = generation,
    endFrame = endFrame,
    gap = false,
    gapReason = nil,
    droppedFrames = 0,
    hops = table.freeze(hops),
    latest = nil,
  }
end

steady = function(record: features.Hop): contract.Steady
  return table.freeze {
    generation = record.generation,
    endFrame = record.endFrame,
    rms = record.rms,
    peak = record.peak,
    bassPower = record.bassPower,
    midPower = record.midPower,
    treblePower = record.treblePower,
    spectrum = record.spectrum,
    leftSpectrum = record.leftSpectrum,
    rightSpectrum = record.rightSpectrum,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'audio-analysis',
  capability = contract.capability,
  requires = { audio.capability, frame.capability },
  schema = config.schema,
  build = build,
}
