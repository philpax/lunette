-- Displays the latest error report on a floating quad because reports have no texture source.
local plugin = require '@lunette-plugin'
local errors = require '@lunette-contracts/errors'
local frame = require '@lunette-contracts/frame'
local format = require '@lunette-plugins/errors/format'

local config = require '@lunette-plugins/desktop/errors/config'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = { errors = errors.capability, frame = frame.capability }

local function draw(pass: Pass, lines: { string }, settings: Settings): boolean
  if #lines == 0 then
    return false
  end
  local x, y, z = settings.position:unpack()
  local textHeight = settings.textHeight
  local height = (#lines + 1) * textHeight * 1.5
  local background = settings.background
  pass:setColor(background[1], background[2], background[3], background[4])
  pass:plane(x, y, z, settings.width, height, 0, 0, 0, 0, 'fill', 1, 1)
  pass:setColor(1, 1, 1, 1)
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
  return true
end

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/errors',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local frameService: frame.Service = context:require(frame.capability)
    local stream: errors.Service = context:require(errors.capability)
    local shown: errors.Report? = nil
    local recent = stream:recent()
    shown = recent[#recent]
    stream:subscribe(context, {
      run = function(report: errors.Report): ()
        shown = report
      end,
      cleared = function(): ()
        shown = nil
      end,
    })
    frameService:onDraw(context, {
      phase = 'overlay',
      run = function(pass: Pass): ()
        local report = shown
        if not report then
          return
        end
        local lines = format.lines(
          { latest = report.text, count = report.sequence },
          { columns = settings.columns, lines = settings.lines }
        )
        draw(pass, lines, settings)
      end,
    })
  end,
}).definition
