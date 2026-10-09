local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local frameProvider = require '@lunette-plugins/frame'
local desktop = require '@lunette-desktop'
local keyboardProvider = require '@lunette-plugins/keyboard'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'

local fixture = {}

-- Boots the shipped desktop with a small keyboard layout and the given entries inserted.
function fixture.boot(additions)
  local native = testing.native()
  local services = {}
  local observer = plugin.define {
    name = 'manager-vr-observer',
    requires = {
      ui = ui.capability,
      focus = focus.capability,
      display = display.capability,
      surfaces = surfaces.capability,
    },
    init = function(context)
      services.ui = context:require(ui.capability)
      services.focus = context:require(focus.capability)
      services.display = context:require(display.capability)
      services.surfaces = context:require(surfaces.capability)
    end,
  }
  local codes = lunette.keyCodes()
  local rows = {
    {
      { label = 'Text', action = { kind = 'text', text = 'next' } },
      { label = 'All', action = { kind = 'chord', code = codes.a, modifiers = { 'control' } } },
    },
  }
  local patches = {
    { id = 'laser', config = { aim = { enabled = false }, triggerLock = { enabled = false } } },
    { id = 'keyboard', definition = keyboardProvider.define { rows = rows, layers = {} } },
    { insert = { id = 'manager-vr-observer', definition = observer } },
  }
  for _, entry in additions do
    patches[#patches + 1] = { insert = entry }
  end
  frameProvider.install { start = function() end, stop = function() end }
  local running = management.start(desktop.compose { patches = patches }, {
    protected = { 'desktop/manager', 'desktop/menu', 'desktop/actions', 'desktop/keyboard', 'desktop/pointing' },
  })
  local controls = vrUi.attach(native)
  controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  controls:tracked('left', true)
  controls:step()
  local env = { native = native, services = services, controls = controls, running = running }
  function env:open()
    self.controls:clickControl(self.services.ui, 'desktop/menu', 'open')
    self.controls:clickControl(self.services.ui, 'desktop/menu', 'actions', 'right', 'desktop/manager/open')
    self.controls:clickControl(self.services.ui, 'desktop/menu/titlebar', 'close')
  end
  function env:click(id, itemId)
    local panel = if id == 'close' then 'desktop/manager/titlebar' else 'desktop/manager'
    self.controls:clickControl(self.services.ui, panel, id, 'right', itemId)
  end
  -- Scrolls a list with the thumbstick until the item is visible, then clicks it.
  function env:item(id, itemId)
    for _ = 1, 128 do
      local description, control = self.controls:discover(self.services.ui, 'desktop/manager', id)
      for _, item in control.items do
        if item.id == itemId and item.bounds then
          self:click(id, itemId)
          return
        end
      end
      local bounds = control.bounds
      self.controls:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 'right')
      self.controls:axis('right', 0, -1)
      self.controls:step(0.04)
      self.controls:axis('right', 0, 0)
      self.controls:step()
    end
    error('list item is not reachable: ' .. itemId)
  end
  function env:visible()
    for _, panel in self.services.ui:panels() do
      local description = panel:describe()
      if description.name == 'desktop/manager' then
        return description.visible
      end
    end
    error 'manager panel is absent'
  end
  function env:key(label)
    local board
    for _, surface in self.services.surfaces:all() do
      if surface.keys and surface.setVisible then
        board = surface
      end
    end
    assert(board, 'the shared keyboard is visible')
    board:setPose(lovr.math.newMat4():translate(0, 0.8, -0.8))
    for _, key in board:keys() do
      if key.legend == label then
        self.controls:click({
          pose = board.pose,
          width = board.width,
          height = board.height,
          logicalWidth = board.width,
          logicalHeight = board.height,
          visible = board.visible,
        }, key.x + key.width / 2, key.y + key.height / 2, 'left')
        return
      end
    end
    error('keyboard has no key ' .. label)
  end
  function env:close()
    self.running.runtime:close()
    self.native.assertResourcesReleased()
  end
  return env
end

return fixture
