-- Native audio declarations satisfy the neutral contract and retain discriminated read-only shapes.
local lunette = require '@lunette'
local audio = require '@lunette-contracts/audio'

local function exercise(
  process: lunette.Process,
  source: lunette.AudioSource,
  state: lunette.AudioState
): { [number]: audio.Snapshot | audio.Source | audio.State }
  local system: lunette.AudioCapture = lunette.openAudio { kind = 'system' }
  local selected: lunette.AudioCapture = lunette.openAudio { kind = 'process', process = process }
  local snapshot: lunette.AudioSnapshot = selected:snapshot()
  local neutral: audio.Snapshot = snapshot
  local neutralSource: audio.Source = source
  local neutralState: audio.State = state
  if source.kind == 'process' then
    local selectedProcess: lunette.Process = source.process
    assert(selectedProcess.id > 0)
  end
  if state.kind == 'unavailable' then
    local reason: audio.UnavailableReason = state.reason
    local detail: string = state.detail
    assert(#reason > 0 and #detail >= 0)
  elseif state.kind == 'active' then
    local provenance: audio.Provenance? = state.provenance
    assert(provenance == nil or #provenance > 0)
  end
  for _, block in snapshot.blocks do
    local neutralBlock: audio.Block = block
    local samples: buffer = block:copySamples()
    local timing: 'sample-frames' = block.timing
    local dropped: number = block.droppedFrames
    assert(buffer.len(samples) == block.frameCount * block.channels * 4)
    assert(block.sampleRate == 48000 and timing == 'sample-frames' and dropped >= 0)
    assert(neutralBlock.sequence == block.sequence)
  end
  system:close()
  selected:close()
  return { neutral, neutralSource, neutralState }
end

return exercise
