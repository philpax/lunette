local testing = require '@testing'
local plugin = require '@lunette-plugin'
local selection = require '../../private/selection/selection'
local attention = require '../../private/selection/attention'
local controls = require '../../private/controls/controls'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local vrUi = require '@testing/vr-ui'
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
  ui: ui.Service,
  menu: menu.Service,
  enabled: () -> boolean,
  processBoundary: ProcessBoundary?,
}
local freshProcesses: (testing.Native) -> ProcessBoundary

function fixture.boot(options: Options?): Environment
  options = options or {}
  local native = testing.native()
  local processBoundary = if options.freshProcesses then freshProcesses(native) else nil
  local choice = selection.new(options.settings)
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
      })
    end,
  }
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
    'ui',
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
    ui = running.session:observe(ui.capability).service,
    menu = running.session:observe(menu.capability).service,
    processBoundary = processBoundary,
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

function fixture.open(env: Environment): ()
  env.running:clickControl(env.ui, 'desktop/menu', 'open')
  env.running:clickControl(env.ui, 'desktop/menu', 'actions', 'right', 'desktop/backdrop/open')
end

function fixture.choice(env: Environment, id: string, item: string): ()
  local description, control = env.running:discover(env.ui, 'desktop/backdrop/controls', id)
  local bounds = control.bounds
  env.running:click(description, bounds.x + bounds.width / 2, bounds.y + 16)
  env.running:clickControl(env.ui, 'desktop/backdrop/controls', id, 'right', item)
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
