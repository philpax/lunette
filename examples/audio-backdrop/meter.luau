-- This consumer reads public PCM and analysis contracts without requiring the desktop or backdrop.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local audio = require '@lunette-contracts/audio'
local analysis = require '@lunette-contracts/audio-analysis'
local schema = require '@lunette-plugin/schema'
local rawLevel = require './raw-level'

local descriptor =
  schema.object { textHeight = schema.default(schema.number { minimum = 0.005, maximum = 0.1 })(0.025) }
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.consumer<<Config, Settings>> {
  name = 'example/audio-meter',
  requires = { frame.capability, audio.capability, analysis.capability },
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings): ()
    local frames = context:require(frame.capability)
    local source: audio.Source = { kind = 'system' }
    local raw = context:require(audio.capability):open(context, source)
    local opened = context:require(analysis.capability):open(context, source)
    local features: analysis.Reader? = nil
    local detail = ''
    if opened.kind == 'success' then
      features = opened.reader
    else
      detail = opened.kind .. ': ' .. opened.detail
    end
    local text = 'Audio meter: starting'
    local pose = lovr.math.newMat4():translate(0, 1.25, -1.7):scale(settings.textHeight)
    frames:onUpdate(context, {
      phase = 'input',
      run = function(_dt: number): ()
        local snapshot = raw:snapshot()
        local reading = rawLevel.read(snapshot)
        text =
          string.format('Audio meter: %s, raw peak %.3f (%d frames)', snapshot.state.kind, reading.peak, reading.frames)
        local reader = features
        if reader then
          local publication = reader:snapshot()
          local latest = publication.latest
          if latest then
            text ..= string.format(
              '\nRMS %.3f, band powers %.4f / %.4f / %.4f, %d new hops',
              latest.rms,
              latest.bassPower,
              latest.midPower,
              latest.treblePower,
              #publication.hops
            )
          else
            text ..= '\nAnalysis: ' .. publication.state.kind
          end
        else
          text ..= '\nAnalysis: ' .. detail
        end
      end,
    })
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass): ()
        pass:text(text, pose)
      end,
    })
  end,
}
