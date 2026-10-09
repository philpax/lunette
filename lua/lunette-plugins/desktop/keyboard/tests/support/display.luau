local testing = require '@testing'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local surfaces = require '@lunette-contracts/surfaces'

local display = require '@lunette-contracts/keyboard-display'
local lunette = require '@lunette'

local fixture = {}

function fixture.start(options)
  options = options or {}
  local env = {}
  local desktop = require '@lunette-plugins/desktop/keyboard'
  local capture = plugin.define {
    name = 'desktop/keyboard',
    requires = desktop.requires,
    provides = desktop.provides,
    init = function(context, _config, publish)
      desktop.init(context, require('@lunette-plugins/desktop/keyboard/config').schema.parse {}, {
        provide = function(_self, capability, service)
          env.rawDisplay = service
          publish:provide(capability, service)
        end,
      })
    end,
  }
  env.session = testing.boot {
    'frame',
    'theme',
    'surfaces',
    options.focus or 'focus',
    options.keyboard or 'keyboard',
    options.ui or 'ui',
    { id = 'desktop/keyboard', definition = capture },
    {
      id = 'fields',
      definition = plugin.define {
        name = 'testing/display-fields',
        requires = { ui = ui.capability, focus = focus.capability },
        init = function(context)
          env.owner = context
          env.focus = context:require(focus.capability)
          env.source = env.focus:newSource(context)
          env.panel = context:require(ui.capability):newPanel(context, {
            name = 'Display fields',
            width = 1,
            height = 1,
            logicalWidth = 200,
            logicalHeight = 200,
          })
          env.first = env.panel:textField(context, {
            id = 'first',
            value = 'draft',
            bounds = { x = 10, y = 10, width = 180, height = 30 },
          })
          env.second = env.panel:textField(context, {
            id = 'second',
            bounds = { x = 10, y = 60, width = 180, height = 30 },
          })
          env.localTarget = function(receiver, wantsKeyboard)
            return env.focus:register(context, {
              kind = 'local',
              receiver = receiver or {
                key = function()
                  return true
                end,
                text = function()
                  return true
                end,
              },
              wantsKeyboard = wantsKeyboard ~= false,
            })
          end
        end,
      },
    },
  }
  env.keyboard = env.session:observe(keyboard.capability)
  env.surfaces = env.session:observe(surfaces.capability)
  env.display = env.session:observe(display.capability)
  env.nativeTarget = function()
    local seat = lunette.newSeat 'display-native'
    env.owner:effect(function()
      return function()
        seat:destroy()
      end
    end)
    return env.focus:register(env.owner, {
      kind = 'native',
      seat = seat,
      sink = env.session.native.newMonitor('display-native').sink,
    })
  end
  return env
end

function fixture.shown(env)
  for _, candidate in env.surfaces.service:all() do
    if candidate.grabbable and candidate.setVisible then
      return candidate
    end
  end
  return nil
end

function fixture.boardCount(env)
  return #env.keyboard.service:inspect().registrations
end

return fixture
