local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

test('keyed components keep their state and host nodes when reordered', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any): ()
      fixture.registerKinds(service, owner, {})
    end,
  }
  local order = ui.store { 'first', 'second' }
  local initialized, cleaned = 0, 0
  local setters = {}
  local Item = ui.component('KeyedItem', function(props: { name: string }): ui.Child
    local value, setValue = ui.useState(function(): number
      initialized += 1
      return initialized
    end)
    setters[props.name] = setValue
    ui.useEffect(function(): () -> ()
      return function(): ()
        cleaned += 1
      end
    end, {})
    return element('test/text', { text = `{props.name} {value}` })
  end)
  local Root = ui.component('KeyedRoot', function(): ui.Child
    return element('test/column', {
      ui.map(ui.useStore(order), function(name: string): ui.Child
        return Item { key = name, name = name }
      end),
    })
  end)
  local handle = ui.mount(state.panel, Root {})
  state.fixture:step()
  local first = assert(state.panel:find 'first')
  local second = assert(state.panel:find 'second')
  setters.first(9)
  state.fixture:step()
  order:set { 'second', 'first' }
  state.fixture:step()
  expect.equal(state.panel:find 'first', first)
  expect.equal(state.panel:find 'second', second)
  expect.equal(first.props.text, 'first 9')
  expect.equal(second.props.text, 'second 2')
  expect.equal(initialized, 2)
  expect.equal(cleaned, 0)
  order:set { 'first' }
  state.fixture:step()
  expect.equal(cleaned, 1)
  expect.truthy(second.dead, 'the removed keyed node is dead')
  expect.equal(state.panel:find 'first', first)
  handle:unmount()
  expect.equal(cleaned, 2)
  state.fixture:close()
end)

return test
