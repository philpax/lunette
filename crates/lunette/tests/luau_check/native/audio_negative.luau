local lunette = require '@lunette'

local function misuse(
  process: lunette.Process,
  source: lunette.AudioSource,
  state: lunette.AudioState,
  snapshot: lunette.AudioSnapshot,
  block: lunette.AudioBlock
)
  local wrongKind: lunette.AudioSource = { kind = 'microphone' } -- reject.
  local missingProcess: lunette.AudioSource = { kind = 'process' } -- reject.
  local numericProcess: lunette.AudioSource = { kind = 'process', process = 4242 } -- reject.
  lunette.openAudio { kind = 'process', process = process.id } -- reject.
  local sampleString: string = block:copySamples() -- reject.
  local timing: 'device-time' = block.timing -- reject.
  source.kind = 'system' -- reject: read-only.
  snapshot.frameGeneration = 0 -- reject: read-only.
  snapshot.blocks[1] = block -- reject: read-only.
  block.frameCount = 0 -- reject: read-only.
  if source.kind == 'system' then
    local selectedProcess: lunette.Process = source.process -- reject.
    assert(selectedProcess.id > 0)
  end
  if state.kind == 'active' then
    local detail: string = state.detail -- reject.
    assert(#detail >= 0)
  end
  assert(wrongKind ~= missingProcess and numericProcess ~= source and #sampleString >= 0 and timing == 'device-time')
end

return misuse
