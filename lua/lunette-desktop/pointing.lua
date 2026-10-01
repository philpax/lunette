-- Two-hand pointing at every surface the desktop's plugins offer.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local laser = require '@lunette-contracts/laser'
local surfaces = require '@lunette-contracts/surfaces'

local required: plugin.Declaration = {
  frame = frame.capability,
  laser = laser.capability,
  surfaces = surfaces.capability,
}

return plugin.define {
  name = 'desktop/pointing',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    -- The consumer takes no options, so any option is a mistake worth naming.
    plugin.options { name = 'desktop/pointing', defaults = {}, config = config }
    local frameService: frame.Service = context:require(frame.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    local laserService: laser.Service = context:require(laser.capability)
    laserService:attach(context)
    -- The pointing phase follows the scene, so the beams pick against this
    -- frame's panels.
    frameService:onUpdate(context, {
      phase = 'pointing',
      run = function(_dt: number)
        laserService:update(surfaceService:all())
      end,
    })
    frameService:onDraw(context, {
      phase = 'pointing',
      run = function(pass: Pass)
        laserService:draw(pass)
      end,
    })
  end,
}
