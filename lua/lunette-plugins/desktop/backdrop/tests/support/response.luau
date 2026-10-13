local plugin = require '@lunette-plugin'
local analysis = require '@lunette-contracts/audio-analysis'
local backdrop = require '@lunette-plugins/desktop/backdrop'
local model = require '@lunette-plugins/desktop/backdrop/model'
local fixture = require './fixture'

local response = {}
type Environment = typeof(fixture.boot(backdrop.create())) & {
  factory: backdrop.Factory,
  model: model.State,
  readers: { analysis.Reader },
  counts: () -> (number, number, number),
  publish: (
    analysis.Source,
    number,
    number,
    { analysis.Hop }?,
    { number }?,
    analysis.State?,
    boolean?,
    { number }?
  ) -> (),
  update: (number, boolean?) -> (),
}

function response.boot(): Environment
  local state: model.State? = nil
  local factory = backdrop.create({}, function(_context: plugin.Context, current: model.State): ()
    state = current
  end)
  local base = fixture.boot(factory)
  local snapshots: { [string | number]: analysis.Snapshot } = {}
  local readers: { analysis.Reader } = {}
  local opened, live, peak = 0, 0, 0
  local function key(source: analysis.Source): string | number
    return if source.kind == 'system' then 'system' else source.process.id
  end
  local function publication(source: analysis.Source): analysis.Snapshot
    return snapshots[key(source)]
      or {
        source = source,
        profile = { size = 2048, hop = 512 },
        state = { kind = 'starting' },
        frameGeneration = 0,
        generation = nil,
        endFrame = nil,
        gap = false,
        droppedFrames = 0,
        hops = {},
        latest = nil,
      }
  end
  base.session:use(plugin.provider<<{}, {}, analysis.Service>>({
    name = 'testing/analysis',
    capability = analysis.capability,
    build = function(context: plugin.Context): analysis.Service
      return {
        open = function(_self: analysis.Service, owner: plugin.Owner, source: analysis.Source): analysis.OpenResult
          local current: analysis.Reader
          local effect: plugin.Effect
          current, effect = context:resource(owner, function(): (analysis.Reader, () -> ())
            opened += 1
            live += 1
            peak = math.max(peak, live)
            local closed = false
            local made: analysis.Reader = {
              source = source,
              profile = { size = 2048, hop = 512 },
              snapshot = function(): analysis.Snapshot
                return publication(source)
              end,
              close = function(): ()
                effect:dispose()
              end,
            }
            readers[#readers + 1] = made
            return made,
              function(): ()
                if not closed then
                  closed = true
                  live -= 1
                end
              end
          end)
          return { kind = 'success', reader = current }
        end,
      }
    end,
  }).definition)
  base.session.runtime:drain()
  assert(state, 'backdrop model initialized')
  local env = base :: Environment
  env.factory, env.model = factory, state
  env.readers = readers
  env.counts = function(): (number, number, number)
    return opened, live, peak
  end
  env.publish = function(
    source: analysis.Source,
    generation: number,
    endFrame: number,
    hops: { analysis.Hop }?,
    powers: { number }?,
    audioState: analysis.State?,
    gap: boolean?,
    spectrum: { number }?
  ): ()
    local old = snapshots[key(source)]
    local steady: analysis.Steady = {
      generation = generation,
      endFrame = if hops and #hops > 0 then hops[#hops].endFrame else endFrame,
      rms = 0.1,
      peak = 0.2,
      bassPower = powers and powers[1] or 0.01,
      midPower = powers and powers[2] or 0.02,
      treblePower = powers and powers[3] or 0.03,
      spectrum = spectrum or { 0.002, 0.003, 0.005, 0.006, 0.007, 0.007, 0.02, 0.01 },
    }
    snapshots[key(source)] = {
      source = source,
      profile = { size = 2048, hop = 512 },
      state = audioState or ({ kind = 'active' } :: analysis.State),
      frameGeneration = if old then old.frameGeneration + 1 else 1,
      generation = generation,
      endFrame = endFrame,
      gap = gap or false,
      droppedFrames = 0,
      latest = steady,
      hops = hops or {},
    }
  end
  env.update = function(dt: number, primary: boolean?): ()
    assert(env.native, 'response fixture has native fake')
    env.native.events.mainSessionVisible = primary == true
    env.session:update(dt)
  end
  return env
end

-- The onset lands in the mid band unless another band is named, matching a band-less model onset.
function response.hop(
  generation: number,
  ending: number,
  onset: number,
  band: ('bass' | 'mid' | 'treble')?
): analysis.Hop
  local chosen = band or 'mid'
  return {
    generation = generation,
    endFrame = ending,
    rms = 0.1,
    peak = 0.2,
    bassPower = 0.01,
    midPower = 0.02,
    treblePower = 0.03,
    spectrum = { 0.002, 0.003, 0.005, 0.006, 0.007, 0.007, 0.02, 0.01 },
    flux = 0.2,
    onset = onset,
    bassOnset = if chosen == 'bass' then onset else 0,
    midOnset = if chosen == 'mid' then onset else 0,
    trebleOnset = if chosen == 'treble' then onset else 0,
  }
end

return response
