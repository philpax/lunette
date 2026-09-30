-- Direct drawing for the current error report.
--
-- This deliberately remains a floating quad rather than a panels-provider panel:
-- an error report has no textured source and must not acquire panel visuals.

local panel = {}

export type Options = {
  read x: number,
  read y: number,
  read z: number,
  read width: number,
  read textHeight: number,
  read lines: number,
  read columns: number,
  read background: { number },
}

export type State = {
  read latest: string?,
  read count: number,
}

export type Formatter = (State, { read columns: number, read lines: number }) -> { string }

function panel.draw(state: State, options: Options, pass: Pass, format: Formatter): boolean
  local lines = format(state, { columns = options.columns, lines = options.lines })
  if #lines == 0 then
    return false
  end

  local height = (#lines + 1) * options.textHeight * 1.5
  local background = options.background
  pass:setColor(background[1], background[2], background[3], background[4])
  pass:plane(options.x, options.y, options.z, options.width, height, 0, 0, 0, 0, 'fill', 1, 1)
  pass:setColor(1, 1, 1, 1)

  local top = options.y + height / 2 - options.textHeight * 1.5
  for index, line in ipairs(lines) do
    pass:text(
      line,
      options.x - options.width / 2 + options.textHeight,
      top - (index - 1) * options.textHeight * 1.5,
      options.z + 0.001,
      options.textHeight,
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

return panel
