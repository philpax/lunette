local testing = require '@testing'
local plugin = require '@lunette-plugin'
local selection = require '../../private/selection/selection'
local attention = require '../../private/selection/attention'
local controls = require '../../private/controls/controls'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'
local uiHost = require '@lunette-contracts/ui-host'
local recorded = require './panels'
local hostFixture = require '@testing/ui-host'
local vrUi = require '@testing/vr-ui'
local uiPanels = require '@testing/ui-panels'
local wristMenu = require '@testing/wrist-menu'
local lunette = require '@lunette'

local fixture = {}

export type Options = {
  read settings: selection.Settings?,
  read audio: boolean?,
  read audioAnalysis: boolean?,
  read freshProcesses: boolean?,
}
export type Process = { id: number, argv: { read [number]: string }, dead: boolean }
export type ProcessBoundary = { read retained: () -> number }
export type Environment = {
  running: vrUi.Fixture,
  native: testing.Native,
  choice: selection.State,
  panels: panels.Service,
  owner: plugin.Owner,
  host: uiHost.Service,
  recorder: recorded.Recorder,
  -- The wrapped host entry's panels, through which the wrist menu is driven.
  menuPanels: uiPanels.Recorder,
  menu: menu.Service,
  enabled: () -> boolean,
  processBoundary: ProcessBoundary?,
  -- The views' sources, whose `models` records each draw of the sky model.
  view: any,
}
local freshProcesses: (testing.Native) -> ProcessBoundary

-- Views over a still backdrop. Its model records the radius and opacity of each call in `models`.
function fixture.view(): any
  local config = require '../../config'
  local model = require '../../private/rendering/model'
  local settings = config.schema.parse {}
  local models: { { radius: number, opacity: number } } = {}
  return {
    observed = { frame = model.new(settings):update(0, true), raw = table.create(model.SPECTRUM_BANDS, 0) },
    palette = settings.palette,
    models = models,
    miniature = function(_pass: Pass, _frame: any, radius: number, _facing: number?, opacity: number): ()
      table.insert(models, { radius = radius, opacity = opacity })
    end,
    sectors = 12,
    hold = 0.65,
    visible = false,
  }
end

function fixture.boot(options: Options?): Environment
  options = options or {}
  local native = testing.native()
  local processBoundary = if options.freshProcesses then freshProcesses(native) else nil
  local choice = selection.new(options.settings)
  local view = fixture.view()
  local enabled = true
  local parent = plugin.consumer {
    name = 'testing/backdrop-source',
    init = function(context: plugin.Context): ()
      attention.attach(context, choice)
      controls.attach(context, choice, {
        enabled = function(): boolean
          return enabled
        end,
        setEnabled = function(value: boolean): ()
          enabled = value
        end,
      }, view)
    end,
  }
  local recorder = recorded.recorder()
  local menuPanels = uiPanels.new()
  local entries = {
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'theme',
    'laser',
    'keyboard',
    'desktop/pointing',
    'panels',
    menuPanels.entry,
    'ui-standard',
    'menu',
    'desktop/menu',
    'desktop/render',
    { id = 'testing/backdrop-source', definition = parent.definition },
  }
  if options.audio or options.audioAnalysis then
    table.insert(entries, 'audio')
  end
  if options.audioAnalysis then
    table.insert(entries, 'audio-analysis')
  end
  local running = vrUi.boot(entries, { native = native })
  local observed = running.session:observe(panels.capability)
  local result = {
    running = running,
    native = native,
    choice = choice,
    panels = observed.service,
    owner = observed.context,
    host = running.session:observe(uiHost.capability).service,
    menuPanels = menuPanels,
    recorder = recorder,
    menu = running.session:observe(menu.capability).service,
    processBoundary = processBoundary,
    view = view,
    enabled = function(): boolean
      return enabled
    end,
  }
  running:tracked('head', true)
  running:pose('head', lovr.math.newMat4():translate(0, 1.5, 0))
  running:pose('left', lovr.math.newMat4():translate(-0.4, 1.1, -0.5))
  running:tracked('left', true)
  return result
end

function fixture.window(
  env: Environment,
  id: number,
  process: lunette.Process,
  x: number?,
  z: number?
): (panels.Surface, testing.Window)
  local window = env.native.newWindow(id, 'org.fixture.Player', process)
  table.insert(env.native.events.windows, window)
  local panel = env.panels:fromWindow(env.owner, window, {
    pose = lovr.math.newMat4():translate(x or 0, 1.5, z or -2),
    width = 1,
    height = 0.5,
  })
  return panel, window
end

-- Opens the panel through the wrist menu, then lowers the menu by losing the left hand's tracking, so the open menu
-- does not cover the panel's lower controls.
function fixture.open(env: Environment): ()
  env.running:tracked('left', true)
  env.running:step(0)
  wristMenu.open(env.running, env.menuPanels)
  env.menuPanels:click(env.running, wristMenu.PANEL, wristMenu.row 'desktop/backdrop/open')
  env.running:tracked('left', false)
  -- The panel renders what the action changed at the next commit.
  env.running:step(0)
end

-- The control panel's node at a key path, such as 'body/enabled'.
function fixture.node(env: Environment, path: string): uiHost.Node
  return recorded.node(env.recorder, controls.PANEL, path)
end

function fixture.click(env: Environment, path: string): ()
  recorded.click(env.running, env.recorder, controls.PANEL, path)
end

function fixture.visible(env: Environment): boolean
  return recorded.visible(env.host, controls.PANEL)
end

-- Opens the diagnostic view menu and chooses an option.
function fixture.diagnostic(env: Environment, id: string): ()
  fixture.click(env, 'body/diagnostics/content/view/trigger')
  env.running:step(0)
  fixture.click(env, 'body/diagnostics/content/view/menu/' .. id)
end

local ROWS = 'body/applications/content/scroll/rows/'

-- The application row with a token, if it is shown.
function fixture.row(env: Environment, token: string): uiHost.Node?
  return recorded.panel(env.recorder, controls.PANEL):find(ROWS .. token)
end

-- The tokens of the shown rows, in token order, searching the serials up to `limit`.
function fixture.rows(env: Environment, limit: number?): { string }
  local tokens: { string } = {}
  for serial = 1, limit or 400 do
    local token = 'application-' .. tostring(serial)
    if fixture.row(env, token) then
      tokens[#tokens + 1] = token
    end
  end
  return tokens
end

-- The geometry centred on a row, for pressing and holding it across frames.
function fixture.rowGeometry(env: Environment, token: string): vrUi.Geometry
  return hostFixture.nodeGeometry(assert(fixture.row(env, token), `no row {token}`))
end

-- Drags a slider's thumb to near `value`, so the release snaps to a nearby detent.
function fixture.slide(env: Environment, path: string, value: number): ()
  recorded.slide(env.running, env.recorder, controls.PANEL, path, value)
end

function fixture.aimHead(env: Environment, x: number?): ()
  env.running:pose('head', lovr.math.newMat4():translate(x or 0, 1.5, 0))
end

-- Native enumerations return fresh handles; equality follows the process, but table keys remain raw.
freshProcesses = function(native: testing.Native): ProcessBoundary
  local wrappers: { [Process]: boolean } = setmetatable({}, { __mode = 'k' })
  local equality = {
    __eq = function(left: Process, right: Process): boolean
      return rawequal(rawget(left, 'identity') or left, rawget(right, 'identity') or right)
    end,
    __index = function(handle: Process, key: string): unknown
      local process = rawget(handle, 'identity')
      return if process then process[key] else nil
    end,
    __newindex = function(handle: Process, key: string, value: unknown): ()
      rawset(rawget(handle, 'identity') or handle, key, value)
    end,
  }
  local newProcess = native.newProcess
  native.newProcess = function(id: number, argv: { string }?): Process
    return setmetatable(newProcess(id, argv), equality)
  end
  local enumerate = lunette.processes
  lunette.processes = function(): { Process }
    local result: { Process } = {}
    for _, process in enumerate() do
      local handle = setmetatable({ identity = process }, equality)
      wrappers[handle] = true
      result[#result + 1] = handle
    end
    return result
  end
  return {
    retained = function(): number
      testing.collect()
      local count = 0
      for _ in wrappers do
        count += 1
      end
      return count
    end,
  }
end

return fixture
