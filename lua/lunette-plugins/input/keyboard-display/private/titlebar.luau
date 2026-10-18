-- The keyboard's titlebar: a UI host panel attached above the board with its title and a Close button. The host
-- keeps it above the board and at its width, and a grab on the bar's empty space grabs the board.
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local keyboard = require '@lunette-contracts/keyboard'
local vocabulary = require '@lunette-contracts/vocabulary'

local titlebar = {}

export type Titlebar = {
  read sync: (Titlebar, boolean) -> (),
  read destroy: (Titlebar) -> (),
}

-- The gap between the bar and the board, in metres.
local GAP = 0.01

function titlebar.new(
  owner: plugin.Owner,
  host: uiHost.Service,
  components: uiComponents.Service,
  board: keyboard.Keyboard,
  close: () -> ()
): Titlebar
  local panel = host:newPanel(owner, {
    name = 'desktop/keyboard/titlebar',
    presentation = 'attach',
    target = (board :: any) :: vocabulary.Surface,
    height = host:theme().sizes.header,
    gap = GAP,
    visible = false,
  })
  panel.root:bind {
    render = function(): ()
      panel.root:submit(components.Panel { title = 'Keyboard', onClose = close })
    end,
  }
  local shown = false
  local result: Titlebar = {
    -- Shows the bar while the board is shown.
    sync = function(_self: Titlebar, visible: boolean): ()
      local show = visible and not board.dead
      if show ~= shown and not panel.dead then
        shown = show
        panel:setVisible(show)
      end
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
