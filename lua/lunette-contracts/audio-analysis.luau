-- Owner-scoped readers share analysis by source and size/hop profile. Publications can be retained across frames.
local plugin = require '@lunette-plugin'
local audio = require '@lunette-contracts/audio'

local analysis = {}

export type Source = audio.Source
export type State = audio.State

-- Omitted options resolve to size 2048 and hop size/4. Only size and hop are options.
export type Options = { read size: number?, read hop: number? }
export type Profile = { read size: number, read hop: number }

-- Band powers sum stereo-averaged one-sided bin powers. Bin centres select the half-open bands:
-- bass [30, 250), mid [250, 2000), and treble [2000, 10000) Hz. Sample rate is 48000 Hz.
-- The periodic Hann spectrum uses abs(FFT)^2/(N*sum(window^2)), doubled except at DC and Nyquist.
-- RMS and peak use the complete unweighted stereo window. endFrame is exclusive sample time within generation.
-- All spectra hold eight band powers with upper edges 60, 120, 250, 500, 1000, 2000, 4000, and 10000 Hz above
-- a 30 Hz floor. leftSpectrum and rightSpectrum retain full channel powers; spectrum averages them per band,
-- so opposite channel phases cannot cancel power. Spectrum bands 1-3 sum to bassPower, 4-6 to midPower, and
-- 7-8 to treblePower. A band that contains no bin centre at the profile's size has zero power.
-- Spectrum arrays and their enclosing records are immutable and can be retained across publications.
export type Steady = {
  read generation: number,
  read endFrame: number,
  read rms: number,
  read peak: number,
  read bassPower: number,
  read midPower: number,
  read treblePower: number,
  read spectrum: { read [number]: number },
  read leftSpectrum: { read [number]: number },
  read rightSpectrum: { read [number]: number },
}

-- Flux sums positive sqrt-bin-power deltas across the bands and divides by the previous magnitude sum,
-- floored at 0.001. Flux clamps to [0, 1] and is zero below RMS 0.001 and on the first window after a reset.
-- Onset is clamp((flux - 0.08)/0.24, 0, 1). A hop describes one completed window, not a render-frame estimate.
-- Band flux restricts the sums to one coarse band and divides by the larger of that band's previous magnitude
-- sum, a tenth of the full-band previous magnitude sum, and 0.001. Band onset is clamp((bandFlux - 0.3)/0.4, 0, 1),
-- so a kick, snare, or hi-hat registers in its own band while steady noise does not.
export type Hop = Steady & {
  read flux: number,
  read onset: number,
  read bassOnset: number,
  read midOnset: number,
  read trebleOnset: number,
}
export type GapReason = 'generation' | 'discontinuity' | 'capacity' | 'invalidSamples' | 'state'

export type Snapshot = {
  read source: Source,
  read profile: Profile,
  read state: State,
  -- This is the native PCM publication generation, distinct from the stream generation below.
  read frameGeneration: number,
  read generation: number?,
  -- Exclusive end of the last processed PCM block within generation, including zero-hop publications.
  -- Nil before the first block; unchanged when a publication contains no new PCM.
  read endFrame: number?,
  read gap: boolean,
  read gapReason: GapReason?,
  read droppedFrames: number,
  -- Ordered completed hops for this publication only, bounded by 94. An empty list never replays an onset.
  read hops: { read [number]: Hop },
  -- Last completed steady values in uninterrupted active history, with no impulses.
  -- State loss or an analysis reset clears latest until a fresh complete window.
  read latest: Steady?,
}

export type Reader = {
  read source: Source,
  read profile: Profile,
  read snapshot: (Reader) -> Snapshot,
  read close: (Reader) -> (),
}

export type OpenResult =
  { read kind: 'success', read reader: Reader }
  | { read kind: 'invalid-options', read detail: string }
  | { read kind: 'capacity-exceeded', read detail: string }

export type Service = {
  -- At most two distinct profiles per source and eight per runtime. Duplicate profiles share both storage and work.
  read open: (Service, plugin.Owner, Source, Options?) -> OpenResult,
}

export type Capability = plugin.Capability<Service>
analysis.capability = plugin.capability<<Service>> { name = 'lunette/audio-analysis', version = 2 }

return analysis
