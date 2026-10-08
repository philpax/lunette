-- Draws the configured hint after panels while no panel exists.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local theme = require '@lunette-contracts/theme'
local passState = require '@lunette-plugins/pass-state'
local descriptors = require '@lunette-plugins/theme/descriptors'

local config = require '@lunette-plugins/desktop/hint/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  frame = frame.capability,
  panels = panels.capability,
  theme = theme.capability,
}

type Paint = {
  revision: number,
  size: number,
  foreground: theme.Color,
  font: theme.FontLease,
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/hint',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local themeService: theme.Service = context:require(theme.capability)
    local position = settings.position
    local configuredFont: theme.FontSpec? = if settings.font
      then descriptors.projectFont(settings.font, 'desktop/hint font')
      else nil
    local function prepare(snapshot: theme.Snapshot): Paint
      local style = snapshot.theme
      return {
        revision = snapshot.revision,
        size = settings.size or style.typography.hintTextHeight,
        foreground = settings.foreground or style.colors.foreground,
        font = themeService:acquireFont(context, configuredFont or style.typography.font),
      }
    end
    local paint = prepare(themeService:current())
    local function applyCurrent(): ()
      if not context:active() then
        return
      end
      local snapshot = themeService:current()
      if snapshot.revision == paint.revision then
        return
      end
      local replacement = prepare(snapshot)
      local previous = paint
      paint = replacement
      previous.font:dispose()
    end
    themeService:onChanged(context, function(_event: theme.Snapshot): ()
      applyCurrent()
    end)

    frameService:onDraw(context, {
      phase = 'scene',
      order = 1,
      run = function(pass: Pass): ()
        local refreshed, refreshFailure = pcall(applyCurrent)
        if #panelService:all() == 0 then
          paint.font:withFont(function(face: Font): ()
            passState.withRestore(pass, function(): ()
              pass:setShader()
              pass:setMaterial(nil)
              pass:setFont(face)
              local foreground = paint.foreground
              pass:setColor(foreground[1], foreground[2], foreground[3], foreground[4])
              pass:text(settings.text, lovr.math.mat4():translate(position):scale(paint.size), 0, 'center', 'middle')
            end)
          end)
        end
        if not refreshed then
          error(refreshFailure, 0)
        end
      end,
    })
  end,
}).definition
