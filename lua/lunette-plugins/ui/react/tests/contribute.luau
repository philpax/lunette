local testing = require '@testing'
local adapter = require '@lunette-plugin/adapter'
local schema = require '@lunette-plugin/schema'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local OUTLET = uiHost.outlet {
  name = 'test/react-outlet',
  version = { major = 1, minor = 0 },
  props = schema.object { entry = schema.string() },
}

local KEY = uiHost.keyOf 'test/react-contributor'

type Props = schema.Output<typeof(OUTLET.props)>

-- A plugin that contributes the component to the outlet through the library.
local function contributor(component: (props: any?) -> ui.Child): any
  return adapter.define {
    name = 'test/react-contributor',
    requires = { uiHost.capability },
    init = function(context: adapter.Context): ()
      ui.contribute(context, OUTLET, component)
    end,
  }
end

local function boot(): fixture.State
  return fixture.boot {
    setup = function(service: uiHost.Service, owner: any): ()
      fixture.registerKinds(service, owner, {})
    end,
  }
end

-- The outlet's own component places the outlet once for each entry, with a button that counts its own presses.
local function host(state: fixture.State, entries: ui.WritableStore<{ string }>): ()
  local Owner = ui.component('OutletOwner', function(): ui.Child
    local list = ui.useStore(entries)
    local placements = {}
    for index, entry in list do
      placements[index] =
        element('lunette/outlet', { key = `place-{index}`, outlet = OUTLET, props = { entry = entry } })
    end
    return element('test/column', {
      element('test/text', { key = 'own', text = 'own content' }),
      placements,
    })
  end)
  ui.mount(state.panel, Owner {}, { owner = state.owner })
end

local function text(state: fixture.State, path: string): string?
  local node = state.panel:find(path)
  return if node then node.props.text else nil
end

test('a contributed component renders with the placement props, keeping its state as they change', function()
  local state = boot()
  local log: { string } = {}
  local Settings = ui.component('Settings', function(props: Props): ui.Child
    local count, setCount = ui.useState(0)
    ui.useEffect(function(): () -> ()
      table.insert(log, `effect {props.entry}`)
      return function(): ()
        table.insert(log, `cleanup {props.entry}`)
      end
    end, { props.entry })
    return element('test/button', {
      key = 'press',
      onActivate = function(): ()
        setCount(count + 1)
      end,
      element('test/text', { key = 'label', text = `{props.entry} {count}` }),
    })
  end)
  local instance = assert(state.fixture.session):use(contributor(Settings))
  local entries = ui.store { 'first' }
  host(state, entries)
  state.fixture:step()
  local path = `place-1/{KEY}/press/label`
  expect.equal(text(state, path), 'first 0', 'the component renders with the placement props')
  fixture.click(state, `place-1/{KEY}/press`)
  state.fixture:step()
  expect.equal(text(state, path), 'first 1', 'its state updates')
  entries:set { 'second' }
  state.fixture:step()
  expect.equal(text(state, path), 'second 1', 'new props render with the state kept')
  expect.equal(table.concat(log, ', '), 'effect first, cleanup first, effect second')
  instance:disable()
  expect.equal(log[#log], 'cleanup second', 'the effects clean up when the contributor ends')
  state.fixture:step()
  expect.equal(state.panel:find(`place-1/{KEY}`), nil, 'the contribution is removed')
  expect.equal(text(state, 'own'), 'own content', 'the outlet owner keeps its content')
  state.fixture:close()
end)

test('each placement renders the contributed component with its own state', function()
  local state = boot()
  local Settings = ui.component('Settings', function(props: Props): ui.Child
    local count, setCount = ui.useState(0)
    return element('test/button', {
      key = 'press',
      onActivate = function(): ()
        setCount(count + 1)
      end,
      element('test/text', { key = 'label', text = `{props.entry} {count}` }),
    })
  end)
  state.fixture.session:use(contributor(Settings))
  host(state, ui.store { 'left', 'right' })
  state.fixture:step()
  fixture.click(state, `place-1/{KEY}/press`)
  state.fixture:step()
  expect.equal(text(state, `place-1/{KEY}/press/label`), 'left 1')
  expect.equal(text(state, `place-2/{KEY}/press/label`), 'right 0', 'the second placement keeps its own state')
  state.fixture:close()
end)

test('a contributed component that fails is reported against its contributor', function()
  local state = boot()
  local Failing = ui.component('Failing', function(_props: Props): ui.Child
    error 'deliberate contribution failure'
  end)
  state.fixture.session:use(contributor(Failing))
  host(state, ui.store { 'one' })
  state.fixture:step()
  local reported = assert(state.fixture.native).events.reported
  local found = false
  for _, report in reported do
    if
      string.find(report.message, 'deliberate contribution failure', 1, true)
      and string.find(report.message, 'contribution from test/react-contributor', 1, true)
    then
      found = true
    end
  end
  table.clear(reported)
  expect.truthy(found, 'the failure names the contributor')
  expect.equal(text(state, 'own'), 'own content', 'the outlet owner keeps its content')
  state.fixture:close()
end)

test('a contributed store subscription failure is reported against its contributor', function()
  local state = boot()
  local store = {
    get = function(): number
      return 1
    end,
    subscribe = function(): () -> ()
      error 'deliberate contribution subscription failure'
    end,
  }
  local Failing = ui.component('FailingStore', function(_props: Props): ui.Child
    return element('test/text', { text = tostring(ui.useStore(store)) })
  end)
  state.fixture.session:use(contributor(Failing))
  host(state, ui.store { 'one' })
  state.fixture:step()
  local reported = assert(state.fixture.native).events.reported
  local found = false
  for _, report in reported do
    if
      string.find(report.message, 'deliberate contribution subscription failure', 1, true)
      and string.find(report.message, 'contribution from test/react-contributor', 1, true)
    then
      found = true
    end
  end
  table.clear(reported)
  expect.truthy(found, 'the subscription failure names the contributor')
  expect.equal(text(state, 'own'), 'own content', 'the outlet owner keeps its content')
  state.fixture:close()
end)

return test
