-- The keyboard's titlebar: a UI host panel above the board with its title and a Close button. The panel follows the
-- board, and moving the panel, as a grab does, moves the board with it.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local keyboard = require '@lunette-contracts/keyboard'
local ui = require '@lunette-plugins/ui/react'

local titlebar = {}

export type Titlebar = {
  -- Shows or hides the bar and places it above the board, following a move of the bar first.
  read sync: (Titlebar, boolean) -> (),
  read destroy: (Titlebar) -> (),
}

-- The bar's largest extent; its content gives its size.
local LIMIT = 4
-- The gap between the bar and the board, in metres.
local MARGIN = 0.01
-- Poses closer than this are the pose the bar was given.
local TOLERANCE = 1e-5

type Props = {
  read width: ui.Store<number>,
  read close: () -> (),
}

local Bar = ui.component('KeyboardTitlebar', function(props: Props): ui.Child
  local c = ui.useComponents()
  local width = ui.useStore(props.width)
  -- The bar spans the board, and grows past a narrow board to fit its title and button.
  return c.Panel {
    c.Column {
      minWidth = width,
      c.Header {
        key = 'header',
        title = 'Keyboard',
        c.Button { key = 'close', label = 'Close', variant = 'band', onActivate = props.close },
      },
    },
  }
end)

local function same(a: Mat4, b: Mat4): boolean
  local left, right = { a:unpack(true) }, { b:unpack(true) }
  for index, value in left do
    if math.abs(value - right[index]) > TOLERANCE then
      return false
    end
  end
  return true
end

function titlebar.new(
  owner: plugin.Owner,
  host: uiHost.Service,
  components: uiComponents.Service,
  board: keyboard.Keyboard,
  close: () -> ()
): Titlebar
  local panel = host:newPanel(owner, {
    name = 'desktop/keyboard/titlebar',
    size = 'content',
    width = LIMIT,
    height = LIMIT,
  })
  panel:setVisible(false)
  local width = ui.store(board.width)
  ui.mount(panel, Bar { width = width, close = close }, { components = components, owner = owner })
  local shown = false
  local placed: Mat4? = nil
  -- The distance from the board's centre to the bar's centre along the board's up axis.
  local function offset(): number
    local _, height = panel:size()
    return board.height / 2 + MARGIN + height / 2
  end
  local result: Titlebar = {
    sync = function(_self: Titlebar, visible: boolean): ()
      if panel.dead then
        return
      end
      local show = visible and not board.dead
      if show ~= shown then
        shown = show
        panel:setVisible(show)
      end
      if not show then
        placed = nil
        return
      end
      local current = panel:pose()
      if placed and not same(current, placed) then
        board:setPose(lovr.math.newMat4(current):translate(0, -offset(), 0))
      end
      width:set(board.width)
      local pose = lovr.math.newMat4(board.pose):translate(0, offset(), 0)
      panel:setPose(pose)
      placed = pose
    end,
    destroy = function(_self: Titlebar): ()
      if not panel.dead then
        panel:destroy()
      end
    end,
  }
  return table.freeze(result)
end

return titlebar
