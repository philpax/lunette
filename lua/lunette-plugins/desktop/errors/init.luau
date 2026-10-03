-- The desktop's error panel: a lunette/errors presenter showing the latest report over the scene. It is a
-- floating quad rather than a panel because a report has no textured source.
local plugin = require '@lunette-plugin'
local errors = require '@lunette-contracts/errors'
local frame = require '@lunette-contracts/frame'
local format = require '@lunette-plugins/errors/format'

-- What a configuration gives: every option optional.
export type Config = {
  read position: { number }?,
  read width: number?,
  read textHeight: number?,
  read columns: number?,
  read lines: number?,
  read background: { number }?,
}

export type Settings = {
  read position: { number },
  read width: number,
  read textHeight: number,
  read columns: number,
  read lines: number,
  read background: { number },
}

local DEFAULTS: Settings = {
  position = { 0, 1.4, -1.1 },
  width = 1.1,
  textHeight = 0.045,
  columns = 64,
  lines = 6,
  background = { 0.15, 0.03, 0.03, 0.85 },
}

local required: plugin.Declaration = { errors = errors.capability, frame = frame.capability }

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/errors', defaults = DEFAULTS, config = config }
  plugin.checkNumbers('desktop/errors', 'position', settings.position, 3)
  plugin.checkNumbers('desktop/errors', 'background', settings.background, 4)
  for _, option in ipairs { 'columns', 'lines' } do
    local value = (settings :: any)[option]
    if value < 1 or value ~= math.floor(value) then
      error('plugin desktop/errors: option ' .. option .. ' is a whole number of at least 1, not ' .. value, 0)
    end
  end
  return settings
end

-- Draws the lines on a quad centred on the position, and answers whether
-- there was anything to draw.
local function draw(pass: Pass, lines: { string }, settings: Settings): boolean
  if #lines == 0 then
    return false
  end
  local x, y, z = settings.position[1], settings.position[2], settings.position[3]
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

return plugin.define {
  name = 'desktop/errors',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings = resolve(config)
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
}
