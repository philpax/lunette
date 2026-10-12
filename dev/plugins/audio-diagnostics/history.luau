-- Interval counters retain transient loss without retaining PCM or replaying a publication.
local audio = require '@lunette-contracts/audio'
local analysis = require '@lunette-contracts/audio-analysis'

local history = {}
export type History = {
  frameGeneration: number?,
  analysisFrameGeneration: number?,
  generation: number?,
  rawGaps: number,
  rawDropped: number,
  generationChanges: number,
  analysisGaps: number,
  analysisDropped: number,
}

function history.new(): History
  return {
    frameGeneration = nil,
    analysisFrameGeneration = nil,
    generation = nil,
    rawGaps = 0,
    rawDropped = 0,
    generationChanges = 0,
    analysisGaps = 0,
    analysisDropped = 0,
  }
end

function history.observe(pending: History, raw: audio.Snapshot, features: analysis.Snapshot?): ()
  if pending.frameGeneration ~= raw.frameGeneration then
    pending.frameGeneration = raw.frameGeneration
    for _, block in raw.blocks do
      if block.gap then
        pending.rawGaps += 1
      end
      pending.rawDropped += block.droppedFrames
      if pending.generation ~= nil and pending.generation ~= block.generation then
        pending.generationChanges += 1
      end
      pending.generation = block.generation
    end
  end
  if features and pending.analysisFrameGeneration ~= features.frameGeneration then
    pending.analysisFrameGeneration = features.frameGeneration
    if features.gap then
      pending.analysisGaps += 1
    end
    pending.analysisDropped += features.droppedFrames
  end
end

function history.take(pending: History): string
  local summary = string.format(
    'interval rawGaps=%d rawDropped=%d generationChanges=%d analysisGaps=%d analysisDropped=%d',
    pending.rawGaps,
    pending.rawDropped,
    pending.generationChanges,
    pending.analysisGaps,
    pending.analysisDropped
  )
  pending.rawGaps = 0
  pending.rawDropped = 0
  pending.generationChanges = 0
  pending.analysisGaps = 0
  pending.analysisDropped = 0
  return summary
end

return history
