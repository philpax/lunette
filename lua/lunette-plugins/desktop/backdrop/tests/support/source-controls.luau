local testing = require '@testing'
local plugin = require '@lunette-plugin'
local selection = require '../../selection'
local attention = require '../../attention'
local controls = require '../../controls'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'
local vrUi = require '@testing/vr-ui'
local lunette = require '@lunette'

local fixture = {}

export type Options = { read settings: selection.Settings?, read audio: boolean? }
export type Environment = {
  running: vrUi.Fixture,
  native: testing.Native,
  choice: selection.State,
  panels: panels.Service,
  owner: plugin.Owner,
  ui: ui.Service,
  menu: menu.Service,
  enabled: () -> boolean,
}

function fixture.boot(options: Options?): Environment
  options = options or {}
  local native = testing.native()
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
  if options.audio then
    table.insert(entries, 'audio')
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

return fixture
