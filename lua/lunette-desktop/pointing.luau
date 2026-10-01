-- Two-hand pointing at every surface the desktop's plugins offer. `laser` is the options each hand's laser
-- is attached with, replacing the default wholesale.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local laser = require '@lunette-contracts/laser'
local surfaces = require '@lunette-contracts/surfaces'

-- What a configuration gives: every option optional.
export type Config = {
  read laser: laser.Options?,
}

export type Settings = {
  read laser: laser.Options,
}

local DEFAULTS: Settings = { laser = {} }

local LASER_OPTIONS: { [string]: string } = {
  name = 'string',
  readInput = 'function',
  tuning = 'table',
  style = 'table',
}

local required: plugin.Declaration = {
  frame = frame.capability,
  laser = laser.capability,
  surfaces = surfaces.capability,
}

-- The laser options replace their default wholesale, so they are checked here. A seat is not among them:
-- two hands sharing a seat would share focus and pointer.
local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/pointing', defaults = DEFAULTS, config = config }
  for key, value in settings.laser :: { [unknown]: unknown } do
    local expected = if type(key) == 'string' then LASER_OPTIONS[key] else nil
    if not expected then
      error(
        'plugin desktop/pointing: unknown option laser.'
          .. tostring(key)
          .. '; the options are name, readInput, style, and tuning',
        0
      )
    end
    if type(value) ~= expected then
      error(
        string.format(
          'plugin desktop/pointing: option laser.%s is a %s, not a %s',
          tostring(key),
          expected,
          type(value)
        ),
        0
      )
    end
  end
  return settings
end

return plugin.define {
  name = 'desktop/pointing',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings = resolve(config)
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
}
