-- Independent owner-scoped readers share native capture without changing playback routing.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'

local audio = {}

export type Source = { read kind: 'system' } | { read kind: 'process', read process: lunette.Process }
export type Provenance = 'pipewire-client' | 'application-metadata'
export type UnavailableReason =
  'no-server'
  | 'no-default-sink'
  | 'invalid-default-sink'
  | 'permission-denied'
  | 'unsupported-format'
  | 'unresolved-attribution'
  | 'capacity-exceeded'
  | 'graph-failure'
export type State =
  { read kind: 'starting' }
  | { read kind: 'active', read provenance: Provenance? }
  | { read kind: 'idle' }
  | { read kind: 'unavailable', read reason: UnavailableReason, read detail: string }
  | { read kind: 'ended' }

-- startFrame is cumulative sample time within generation, not a fabricated PipeWire timestamp.
export type Block = {
  read sequence: number,
  read generation: number,
  read frameCount: number,
  read sampleRate: number,
  read channels: number,
  read startFrame: number,
  read timing: 'sample-frames',
  read gap: boolean,
  read droppedFrames: number,
  read copySamples: (Block) -> buffer,
}

export type Snapshot = {
  read source: Source,
  read state: State,
  read frameGeneration: number,
  read blocks: { read [number]: Block },
}

export type Reader = {
  read source: Source,
  read snapshot: (Reader) -> Snapshot,
  read close: (Reader) -> (),
}

export type ProcessStatus = {
  read process: lunette.Process,
  read label: string,
  read state: State?,
}

export type Service = {
  read processes: (Service) -> { ProcessStatus },
  read open: (Service, plugin.Owner, Source) -> Reader,
}

export type Capability = plugin.Capability<Service>
audio.capability = plugin.capability<<Service>> { name = 'lunette/audio', version = 1 }

return audio
