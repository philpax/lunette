-- Two-hand pointing at every surface the desktop's consumers offer.
local plugin = require '@lunette-plugin'
local callbacks = require '../desktop/callbacks'
local laser = require '@lunette-contracts/laser'

local required: plugin.Declaration = { laser = laser.capability }
export type Config = { read callbacks: typeof(callbacks) }

return plugin.define(
  function(config: Config): Config
    return config
  end,
  required,
  {},
  function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local callbacks = config.callbacks
    local laserService: laser.Service = context:require(laser.capability)
    laserService:attach(context)
    -- After the panels update, so the beams pick against this frame's panels.
    callbacks.onUpdate(context, function(_dt: number)
      laserService:update(callbacks.surfaces())
    end, 110)
    callbacks.onDraw(context, function(pass: Pass)
      laserService:draw(pass)
    end, 300)
  end
)
