-- Attaches two-hand pointing to the surfaces offered by desktop plugins.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local laser = require '@lunette-contracts/laser'
local surfaces = require '@lunette-contracts/surfaces'

type Config = {}
type Settings = {}

local required: plugin.Declaration = {
  frame.capability,
  laser.capability,
  surfaces.capability,
}

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/pointing',
  requires = required,
  init = function(context: plugin.Context, _settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    local laserService: laser.Service = context:require(laser.capability)
    -- The laser entry's configuration applies to both hands.
    laserService:attach(context)
    -- Picking follows this frame's scene geometry; feedback draws after overlay UI.
    frameService:onUpdate(context, {
      phase = 'pointing',
      run = function(_dt: number)
        laserService:update(surfaceService:all())
      end,
    })
    frameService:onDraw(context, {
      phase = 'feedback',
      run = function(pass: Pass)
        laserService:draw(pass)
      end,
    })
  end,
}
