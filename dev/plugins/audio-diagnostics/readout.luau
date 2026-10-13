-- Diagnostics format public snapshot metadata without retaining PCM or invoking a renderer.
local audio = require '@lunette-contracts/audio'
local analysis = require '@lunette-contracts/audio-analysis'

local readout = {}

function readout.source(source: audio.Source): string
  return if source.kind == 'system' then 'system' else 'process ' .. source.process.id
end

function readout.format(raw: audio.Snapshot, features: analysis.Snapshot?): string
  local state = raw.state
  local provenance = if state.kind == 'active' then state.provenance or 'none' else 'none'
  local lines = {
    string.format(
      'audio source=%s state=%s frame=%d provenance=%s',
      readout.source(raw.source),
      state.kind,
      raw.frameGeneration,
      provenance
    ),
  }
  if state.kind == 'unavailable' then
    lines[#lines + 1] = state.reason .. ': ' .. state.detail
  end
  local block = raw.blocks[#raw.blocks]
  if block then
    local dropped = 0
    local gap = false
    for index = 1, #raw.blocks do
      dropped += raw.blocks[index].droppedFrames
      gap = gap or raw.blocks[index].gap
    end
    lines[#lines + 1] = string.format(
      'PCM %d Hz/%d channels/F32LE seq=%d generation=%d start=%d frames=%d gap=%s dropped=%d',
      block.sampleRate,
      block.channels,
      block.sequence,
      block.generation,
      block.startFrame,
      block.frameCount,
      tostring(gap),
      dropped
    )
  else
    lines[#lines + 1] = 'PCM: no blocks in this publication'
  end
  if features then
    lines[#lines + 1] = string.format(
      'analysis state=%s frame=%d generation=%s size=%d hop=%d hops=%d gap=%s reason=%s dropped=%d',
      features.state.kind,
      features.frameGeneration,
      tostring(features.generation),
      features.profile.size,
      features.profile.hop,
      #features.hops,
      tostring(features.gap),
      features.gapReason or 'none',
      features.droppedFrames
    )
    local latest = features.latest
    if latest then
      lines[#lines + 1] = string.format(
        'RMS=%.4f peak=%.4f powers bass=%.6f mid=%.6f treble=%.6f end=%d',
        latest.rms,
        latest.peak,
        latest.bassPower,
        latest.midPower,
        latest.treblePower,
        latest.endFrame
      )
      local levels = table.create(#latest.spectrum, '')
      for band, power in latest.spectrum do
        -- Power is a mean square, so ten log10 gives decibels relative to full scale.
        levels[band] = if power > 0 then string.format('%.0f', 10 * math.log10(power)) else '-inf'
      end
      lines[#lines + 1] = 'spectrum dBFS=' .. table.concat(levels, ' ')
    end
    local last = features.hops[#features.hops]
    if last then
      lines[#lines + 1] = string.format(
        'onsets full=%.2f bass=%.2f mid=%.2f treble=%.2f',
        last.onset,
        last.bassOnset,
        last.midOnset,
        last.trebleOnset
      )
    end
  end
  return table.concat(lines, '\n')
end

return readout
