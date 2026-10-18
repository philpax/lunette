local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local function boot(): fixture.State
  return fixture.boot {
    setup = function(service: uiHost.Service, owner: any): ()
      fixture.registerKinds(service, owner, {})
    end,
  }
end

local function text(state: fixture.State, path: string): string?
  local node = state.panel:find(path)
  return if node then node.props.text else nil
end

test('contexts use their default or the nearest matching provider', function()
  local state = boot()
  local first, second = ui.createContext 'same default', ui.createContext 'same default'
  local values = ui.store { outer = 'outer', inner = 'inner', sibling = 'sibling' }
  local Reader = ui.component('ContextReader', function(props: { name: string }): ui.Child
    return element('test/text', {
      key = props.name,
      text = `{ui.useContext(first)} / {ui.useContext(second)}`,
    })
  end)
  local Root = ui.component('ContextRoot', function(): ui.Child
    local current = ui.useStore(values)
    return element('test/column', {
      Reader { key = 'default', name = 'default' },
      ui.provide(
        first,
        current.outer,
        element('test/column', {
          key = 'outer',
          Reader { key = 'outer-reader', name = 'outer-reader' },
          ui.provide(first, current.inner, Reader { key = 'inner-reader', name = 'inner-reader' }),
          ui.provide(second, 'other context', Reader { key = 'other-reader', name = 'other-reader' }),
        })
      ),
      ui.provide(first, current.sibling, Reader { key = 'sibling-reader', name = 'sibling-reader' }),
    })
  end)
  ui.mount(state.panel, Root {})
  state.fixture:step()
  expect.equal(text(state, 'default'), 'same default / same default')
  expect.equal(text(state, 'outer/outer-reader'), 'outer / same default')
  expect.equal(text(state, 'outer/inner-reader'), 'inner / same default')
  expect.equal(text(state, 'outer/other-reader'), 'outer / other context')
  expect.equal(text(state, 'sibling-reader'), 'sibling / same default')
  values:set { outer = 'changed', inner = 'inner', sibling = 'sibling' }
  state.fixture:step()
  expect.equal(text(state, 'outer/outer-reader'), 'changed / same default')
  expect.equal(
    text(state, 'outer/inner-reader'),
    'inner / same default',
    'the inner value shadows the changed outer value'
  )
  expect.equal(text(state, 'outer/other-reader'), 'changed / other context')
  expect.equal(text(state, 'sibling-reader'), 'sibling / same default', 'a sibling provider is independent')
  state.fixture:close()
end)

test('a provider keeps its component state across value changes and separates mounts', function()
  local state = boot()
  local context = ui.createContext(0)
  local value = ui.store(1)
  local initialized, cleaned = 0, 0
  local Reader = ui.component('StatefulContextReader', function(): ui.Child
    local identity = ui.useState(function(): number
      initialized += 1
      return initialized
    end)
    ui.useEffect(function(): () -> ()
      return function(): ()
        cleaned += 1
      end
    end, {})
    return element('test/text', { text = `{ui.useContext(context)} / {identity}` })
  end)
  local Root = ui.component('StatefulContextRoot', function(): ui.Child
    return ui.provide(context, ui.useStore(value), Reader {})
  end)
  local handle = ui.mount(state.panel, Root {})
  state.fixture:step()
  expect.equal(text(state, ''), '1 / 1')
  value:set(2)
  state.fixture:step()
  expect.equal(text(state, ''), '2 / 1', 'a provider value change preserves its child instance')
  expect.equal(initialized, 1)
  handle:unmount()
  expect.equal(cleaned, 1)
  state.fixture:step()
  ui.mount(state.panel, Root {})
  state.fixture:step()
  expect.equal(text(state, ''), '2 / 2', 'a new mount has independent hook state')
  state.fixture:close()
  expect.equal(cleaned, 2)
end)

return test
