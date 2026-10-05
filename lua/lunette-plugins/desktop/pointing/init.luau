-- Attaches two-hand pointing to the surfaces offered by desktop plugins.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local laser = require '@lunette-contracts/laser'
local surfaces = require '@lunette-contracts/surfaces'

local config = require '@lunette-plugins/desktop/pointing/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  frame = frame.capability,
  laser = laser.capability,
  surfaces = surfaces.capability,
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/pointing',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    local laserService: laser.Service = context:require(laser.capability)
    laserService:attach(context, settings.laser)
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
}).definition
