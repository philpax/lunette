-- The draw handler ends when the plugin activation ends.

local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'

export type Config = {}
export type Settings = {}

return plugin.consumer<<Config, Settings>> {
  name = 'hello',
  requires = { frame.capability },
  init = function(context: plugin.Context, _settings: Settings)
    local frames: frame.Service = context:require(frame.capability)
    local pose = lovr.math.newMat4():translate(0, 1.6, -1.5):scale(0.1)
    frames:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass)
        pass:text('hello from a plugin', pose)
      end,
    })
  end,
}
