-- Displays the latest error report on a floating quad because reports have no texture source.
local plugin = require '@lunette-plugin'
local errors = require '@lunette-contracts/errors'
local frame = require '@lunette-contracts/frame'
local theme = require '@lunette-contracts/theme'
local errorLines = require '@self/private/lines'
local passState = require '@lunette-plugins/graphics/pass-state'
local descriptors = require '@lunette-plugins/theme/configuration'

local config = require '@self/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  errors.capability,
  frame.capability,
  theme.capability,
}

type Paint = {
  textHeight: number,
  background: theme.Color,
  foreground: theme.Color,
  font: Font,
}

local function draw(pass: Pass, lines: { string }, settings: Settings, paint: Paint): ()
  if #lines == 0 then
    return
  end
  passState.withRestore(pass, function(): ()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setFont(paint.font)
    local x, y, z = settings.position:unpack()
    local textHeight = paint.textHeight
    local height = (#lines + 1) * textHeight * 1.5
    local background = paint.background
    pass:setColor(background[1], background[2], background[3], background[4])
    pass:plane(x, y, z, settings.width, height, 0, 0, 0, 0, 'fill', 1, 1)
    local foreground = paint.foreground
    pass:setColor(foreground[1], foreground[2], foreground[3], foreground[4])
    local top = y + height / 2 - textHeight * 1.5
    for index, line in ipairs(lines) do
      pass:text(
        line,
        x - settings.width / 2 + textHeight,
        top - (index - 1) * textHeight * 1.5,
        z + 0.001,
        textHeight,
        0,
        0,
        1,
        0,
        0,
        'left',
        'middle'
      )
    end
  end)
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/errors',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local stream: errors.Service = context:require(errors.capability)
    local themeService: theme.Service = context:require(theme.capability)
    local configuredFont: theme.FontSpec? = if settings.font
      then descriptors.projectFont(settings.font, 'desktop/errors font')
      else nil
    local function prepare(snapshot: theme.Snapshot): Paint
      local style = snapshot.theme
      local fontSpec = configuredFont or style.typography.font
      return {
        textHeight = settings.textHeight or style.typography.errorTextHeight,
        background = settings.background or style.colors.errorBackground,
        foreground = settings.foreground or style.colors.foreground,
        font = themeService:font(fontSpec),
      }
    end
    local paint = prepare(themeService:current())
    themeService:onChanged(context, {
      run = function(_event: theme.Snapshot): ()
        if context:active() then
          paint = prepare(themeService:current())
        end
      end,
    })

    local shown: errors.Report? = nil
    shown = stream:latest()
    stream:onReport(context, {
      run = function(report: errors.Report): ()
        shown = report
      end,
    })
    frameService:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass): ()
        local report = shown
        if report then
          local lines = errorLines.of(
            { latest = report.text, count = report.sequence },
            { columns = settings.columns, lines = settings.lines }
          )
          draw(pass, lines, settings, paint)
        end
      end,
    })
  end,
}
