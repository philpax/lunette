-- The line of text an empty scene shows.
--
-- While no panel exists, the consumer draws `text` at `position`, `size`
-- metres tall, after the panels in the scene phase.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'

-- What a configuration gives: every option optional.
export type Config = {
  read text: string?,
  read position: { number }?,
  read size: number?,
}

export type Settings = {
  read text: string,
  read position: { number },
  read size: number,
}

local DEFAULTS: Settings = { text = 'lunette: no windows yet', position = { 0, 1.5, -1.5 }, size = 0.08 }

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
}

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/hint', defaults = DEFAULTS, config = config }
  plugin.checkNumbers('desktop/hint', 'position', settings.position, 3)
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
          pass:text(
            settings.text,
            lovr.math.mat4():translate(position[1], position[2], position[3]):scale(settings.size),
            0,
            'center',
            'middle'
          )
        end
      end,
    })
  end,
}
