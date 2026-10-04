-- Draws the configured hint after panels while no panel exists.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'

export type Config = {
  read text: string?,
  read position: vector?,
  read size: number?,
}

export type Settings = {
  read text: string,
  read position: vector,
  read size: number,
}

local DEFAULTS: Settings = { text = 'lunette: no windows yet', position = vector.pack(0, 1.5, -1.5), size = 0.08 }

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
}

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/hint', defaults = DEFAULTS, config = config }
  plugin.checkVector('desktop/hint', 'position', settings.position)
  if not (settings.size > 0) then
    error('plugin desktop/hint: option size is a positive number, not ' .. settings.size, 0)
  end
  return settings
end

return plugin.define {
  name = 'desktop/hint',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings = resolve(config)
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local position = settings.position
    frameService:onDraw(context, {
      phase = 'scene',
      order = 1,
      run = function(pass: Pass)
        if #panelService:all() == 0 then
          pass:text(settings.text, lovr.math.mat4():translate(position):scale(settings.size), 0, 'center', 'middle')
        end
      end,
    })
  end,
}
