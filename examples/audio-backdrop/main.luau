-- The shipped backdrop and an independent meter share audio without sharing visualisation policy.
local desktop = require '@lunette-desktop'
local meter = require './meter'

-- The meter can instead run with only frame, audio, and audio-analysis providers, as its local tests do.
desktop.run {
  settings = {
    ['desktop/backdrop'] = { enabled = true, brightness = 0.55, response = 0.6, motion = 0.25 },
  },
  patches = {
    { insert = { id = 'example/audio-meter', definition = meter.definition } },
  },
}
