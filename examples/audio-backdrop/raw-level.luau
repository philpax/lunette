-- A bounded raw-PCM reading demonstrates the copy boundary without duplicating streaming analysis.
local audio = require '@lunette-contracts/audio'

local level = {}

export type Reading = {
  read frames: number,
  read peak: number,
  read sequence: number?,
  read generation: number?,
}

function level.read(snapshot: audio.Snapshot): Reading
  local block = snapshot.blocks[#snapshot.blocks]
  if not block then
    return { frames = 0, peak = 0 }
  end
  local samples = block:copySamples()
  local frames = math.min(block.frameCount, 256)
  local peak = 0
  for index = 0, frames * block.channels - 1 do
    peak = math.max(peak, math.abs(buffer.readf32(samples, index * 4)))
  end
  return { frames = frames, peak = peak, sequence = block.sequence, generation = block.generation }
end

return level
