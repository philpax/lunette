-- Draws the configured hint after panels while no panel exists.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'

local config = require '@lunette-plugins/desktop/hint/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/hint',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
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
}).definition
