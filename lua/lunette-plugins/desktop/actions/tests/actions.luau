local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local display = require '@lunette-contracts/keyboard-display'
local menu = require '@lunette-contracts/menu'
local actions = require('@lunette-plugins/desktop/actions').definition
local expect = testing.expect
local test = testing.suite()

type Sessions = typeof(require '@testing/session')
type DisplayFixture = {
  dead: boolean,
  isVisible: () -> boolean,
  toggle: () -> boolean,
  onChanged: (DisplayFixture, plugin.Owner, display.Listener) -> plugin.Effect,
}
type State = {
  visible: boolean,
  listeners: { [display.Listener]: boolean },
  service: DisplayFixture,
  session: Sessions.Session,
  menu: menu.Service,
  change: (State, boolean) -> (),
}

local function boot(): State
  local state: State = { visible = false, listeners = {} }
  state.session = testing.boot {
    'menu',
    {
      id = 'display',
      definition = adapter.define {
        name = 'testing/display',
        provides = { display.capability },
        init = function(context: adapter.Context, _: {}, provide: adapter.Publisher)
          state.service = {
            dead = false,
            isVisible = function(): boolean
              return state.visible
            end,
            toggle = function(): boolean
              state:change(not state.visible)
              return true
            end,
            onChanged = function(_self: DisplayFixture, owner: plugin.Owner, listener: display.Listener): plugin.Effect
              state.listeners[listener] = true
              return context:acquire(owner, function(): () -> ()
                return function()
                  state.listeners[listener] = nil
                end
              end)
            end,
          }
          provide:provide(display.capability, state.service)
        end,
      },
    },
    { id = 'desktop/actions', definition = actions },
  }
  state.menu = state.session:observe(menu.capability).service
  function state.change(self: State, value: boolean)
    self.visible = value
    for listener in self.listeners do
      listener.run { visible = value, reason = if value then 'show' else 'hide', revision = 1 }
    end
  end
  return state
end

test('Keyboard is marked selected while the keyboard is visible', function()
  local env = boot()
  local listed = env.menu:list()
  expect.equal(listed[1].id, 'desktop/keyboard/toggle', 'Keyboard comes first')
  expect.equal(listed[2].id, 'desktop/reload', 'Reload comes second')
  expect.equal(listed[1].selected, false, 'a hidden keyboard')
  env:change(true)
  expect.equal(env.menu:list()[1].selected, true, 'a keyboard shown elsewhere')
end)

test('a refused reload is logged', function()
  local env = boot()
  local reload, log = lunette.reload, lovr.log
  local messages: { string } = {}
  lunette.reload = function(): (boolean, string)
    return false, 'reload already pending'
  end
  lovr.log = function(message: string, level: 'debug' | 'info' | 'warn' | 'error')
    messages[#messages + 1] = level .. ': ' .. message
  end
  local result = env.menu:invoke 'desktop/reload'
  lunette.reload, lovr.log = reload, log
  expect.equal(result.kind, 'invoked', 'the action runs')
  expect.equal(table.concat(messages, '|'), 'error: configuration was not reloaded: reload already pending')
end)

test('Reload stays available while the keyboard display is unavailable', function()
  local env = boot()
  env.session.instances.display:disable()
  local listed = env.menu:list()
  expect.equal(#listed, 1, 'only Reload remains')
  expect.equal(listed[1].id, 'desktop/reload', 'Reload remains')
  env.session.instances.display:enable()
  expect.equal(#env.menu:list(), 2, 'Keyboard returns with the display')
end)

return test
