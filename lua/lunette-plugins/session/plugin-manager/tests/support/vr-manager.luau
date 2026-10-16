local testing = require '@testing'
local lunette = require '@lunette'
local adapter = require '@lunette-plugin/adapter'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local frameProvider = require '@lunette-plugins/session/frame'
local desktop = require '@lunette-desktop'
local keyboardProvider = require '@lunette-plugins/input/keyboard'
local ui = require '@lunette-contracts/ui'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local composition = require '@lunette-contracts/composition'
local frame = require '@lunette-contracts/frame'
local menu = require '@lunette-contracts/menu'
local focus = require '@lunette-contracts/focus'
local display = require '@lunette-contracts/keyboard-display'
local surfaces = require '@lunette-contracts/surfaces'
local config = require '../../config'
local shell = require '../../private/presentation/shell'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local wristMenu = require '@testing/wrist-menu'

type Services = {
  ui: ui.Service,
  host: uiHost.Service,
  focus: focus.Service,
  display: display.Service,
  surfaces: surfaces.Service,
  composition: composition.Service,
}
export type Environment = {
  native: testing.Native,
  services: Services,
  controls: vrUi.Fixture,
  running: management.Running,
  -- The manager's panels by name, as it created them.
  panels: { [string]: uiHost.Panel },
  open: (Environment) -> (),
  node: (Environment, string, string?) -> uiHost.Node,
  click: (Environment, string, string?) -> (),
  reveal: (Environment, string, string) -> (),
  entry: (Environment, string) -> composition.Entry?,
  visible: (Environment) -> boolean,
  key: (Environment, string) -> (),
  close: (Environment) -> (),
}

local fixture = {}

local MANAGER = 'desktop/manager'

-- The manager entry as the shipped desktop composes it, recording the panels it opens so tests can address nodes.
local function recordingManager(panels: { [string]: uiHost.Panel }): adapter.Definition<config.Config>
  return plugin.consumer({
    name = MANAGER,
    schema = config.schema,
    requires = {
      composition.capability,
      frame.capability,
      uiHost.capability,
      uiComponents.capability,
      menu.capability,
      focus.capability,
    },
    init = function(context: plugin.Context, settings: config.Settings): ()
      local host = context:require(uiHost.capability)
      shell.start(context, settings, {
        composition = context:require(composition.capability),
        frame = context:require(frame.capability),
        menu = context:require(menu.capability),
        host = host,
        components = context:require(uiComponents.capability),
        focus = context:require(focus.capability),
        open = function(options: uiHost.PanelOptions): uiHost.Panel
          local panel = host:newPanel(context, options)
          panels[options.name] = panel
          return panel
        end,
      })
    end,
  }).definition
end

-- Boots the shipped desktop with a small keyboard layout and the given entries inserted.
function fixture.boot(additions: { testing.ComposeEntry }): Environment
  local native = testing.native()
  local services: Services = {} :: any
  local panels: { [string]: uiHost.Panel } = {}
  local observer = adapter.define {
    name = 'manager-vr-observer',
    requires = {
      ui.capability,
      uiHost.capability,
      focus.capability,
      display.capability,
      surfaces.capability,
      composition.capability,
    },
    init = function(context: adapter.Context): ()
      services.ui = context:require(ui.capability)
      services.host = context:require(uiHost.capability)
      services.focus = context:require(focus.capability)
      services.display = context:require(display.capability)
      services.surfaces = context:require(surfaces.capability)
      services.composition = context:require(composition.capability)
    end,
  }
  local codes = lunette.keyCodes()
  local rows: { keyboardProvider.KeyRow } = {
    {
      { label = 'Text', action = { kind = 'text', text = 'next' } },
      { label = 'All', action = { kind = 'chord', code = codes.a, modifiers = { 'control' } } },
      { label = 'Enter', code = codes.enter },
    },
  }
  local recorder = uiPanels.new()
  local patches: { testing.Patch } = {
    { id = 'ui-host', definition = recorder.definition },
    { id = 'laser', config = { aim = { enabled = false }, triggerLock = { enabled = false } } },
    { id = 'keyboard', definition = keyboardProvider.define { rows = rows, layers = {} } },
    { id = MANAGER, definition = recordingManager(panels) },
    { insert = { id = 'manager-vr-observer', definition = observer } },
  }
  for _, entry in additions do
    patches[#patches + 1] = { insert = entry }
  end
  frameProvider.install {
    start = function(): () end,
    stop = function(): () end,
  }
  local running = management.start(desktop.compose { patches = patches }, {
    protected = { MANAGER, 'desktop/menu', 'desktop/actions', 'desktop/keyboard', 'desktop/pointing' },
  })
  local controls = vrUi.attach(native)
  controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  controls:tracked('left', true)
  controls:step()
  local env: Environment = {
    native = native,
    services = services,
    controls = controls,
    running = running,
    panels = panels,
  } :: any
  function env.open(self: Environment): ()
    wristMenu.run(self.controls, recorder, 'desktop/manager/open')
    self.controls:step()
  end
  function env.node(self: Environment, path: string, panelName: string?): uiHost.Node
    local name = panelName or MANAGER
    local panel = assert(self.panels[name], `the manager has no panel {name}`)
    return assert(panel:find(path), `no node at {name}:{path}`)
  end
  -- Clicks the centre of the node at the key path with the right controller.
  function env.click(self: Environment, path: string, panelName: string?): ()
    local node = self:node(path, panelName)
    self.controls:click(
      { pose = node:pose(), width = 1, height = 1, logicalWidth = 1, logicalHeight = 1, visible = true },
      0.5,
      0.5,
      'right'
    )
    self.controls:step()
  end
  -- Scrolls the scroll box with the thumbstick until the node is inside it.
  function env.reveal(self: Environment, box: string, path: string): ()
    for _ = 1, 400 do
      local frame = self:node(box):panelBounds()
      local target = self:node(path):panelBounds()
      if target.y >= frame.y - 1e-6 and target.y + target.height <= frame.y + frame.height + 1e-6 then
        self.controls:axis('right', 0, 0)
        self.controls:step()
        return
      end
      local scroller = self:node(box)
      self.controls:aim(
        { pose = scroller:pose(), width = 1, height = 1, logicalWidth = 1, logicalHeight = 1, visible = true },
        0.5,
        0.5,
        'right'
      )
      -- Pushing the stick down scrolls down, revealing a node below the box.
      self.controls:axis('right', 0, if target.y > frame.y then -1 else 1)
      self.controls:step(0.04)
    end
    error(`the node {path} does not scroll into view`)
  end
  function env.entry(self: Environment, id: string): composition.Entry?
    for _, entry in self.services.composition:entries() do
      if entry.id == id then
        return entry
      end
    end
    return nil
  end
  function env.visible(self: Environment): boolean
    for _, registration in self.services.host:inspect().registrations do
      if registration.name == MANAGER and registration.live then
        return registration.details.visible == true
      end
    end
    error 'manager panel is absent'
  end
  function env.key(self: Environment, label: string): ()
    local board: keyboardProvider.Board?
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
  function env.close(self: Environment): ()
    self.running.runtime:close()
    self.native.assertResourcesReleased()
  end
  return env
end

return fixture
