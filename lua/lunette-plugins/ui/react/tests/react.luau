local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local function boot()
  local state = fixture.boot {
    setup = function(service, owner)
      fixture.registerKinds(service, owner, {})
    end,
  }
  return state
end

local function label(state: fixture.State, path: string): string?
  local node = state.panel:find(path)
  return if node then node.props.text else nil
end

test('state set from an event re-renders the component', function()
  local state = boot()
  local Counter = ui.component('Counter', function()
    local count, setCount = ui.useState(0)
    return element('test/column', {
      padding = 0.01,
      element('test/button', {
        key = 'go',
        onActivate = function()
          setCount(function(current)
            return current + 1
          end)
        end,
        element('test/text', { key = 'label', text = `count {count}` }),
      }),
    })
  end)
  ui.mount(state.panel, Counter {})
  state.fixture:step()
  expect.equal(label(state, 'go/label'), 'count 0')
  fixture.click(state, 'go')
  state.fixture:step()
  expect.equal(label(state, 'go/label'), 'count 1')
  state.fixture:close()
end)

test('a child with unchanged props is not rendered again', function()
  local state = boot()
  local renders = { parent = 0, child = 0 }
  local Child = ui.component('Child', function(props: { text: string })
    renders.child += 1
    return element('test/text', { key = 'child', text = props.text })
  end)
  local bump: ((number) -> ())? = nil
  local Parent = ui.component('Parent', function()
    renders.parent += 1
    local tick, setTick = ui.useState(0)
    bump = setTick
    return element('test/column', {
      element('test/text', { key = 'tick', text = tostring(tick) }),
      Child { key = 'stable', text = 'same', onAnything = function() end },
    })
  end)
  ui.mount(state.panel, Parent {})
  state.fixture:step()
  assert(bump)(1)
  state.fixture:step()
  expect.equal(renders.parent, 2)
  expect.equal(renders.child, 1, 'the child rendered once')
  expect.equal(label(state, 'tick'), '1')
  expect.equal(label(state, 'stable'), 'same', 'the child keeps its output')
  state.fixture:close()
end)

test('effects run after the render pass and clean up on unmount', function()
  local state = boot()
  local log: { string } = {}
  local Effectful = ui.component('Effectful', function(props: { value: number })
    ui.useEffect(function()
      table.insert(log, `run {props.value}`)
      return function()
        table.insert(log, `clean {props.value}`)
      end
    end, { props.value })
    return element('test/leaf', { width = 0.01, height = 0.01 })
  end)
  local value = ui.store(1)
  local Root = ui.component('Root', function()
    return Effectful { value = ui.useStore(value) }
  end)
  local handle = ui.mount(state.panel, Root {})
  state.fixture:step()
  expect.equal(table.concat(log, ','), 'run 1')
  value:set(2)
  state.fixture:step()
  expect.equal(table.concat(log, ','), 'run 1,clean 1,run 2')
  handle:unmount()
  state.fixture:step()
  expect.equal(table.concat(log, ','), 'run 1,clean 1,run 2,clean 2')
  expect.equal(state.panel:find '#1', nil, 'the content is removed')
  state.fixture:close()
end)

test('a context change reaches a child whose props did not change', function()
  local state = boot()
  local Theme = ui.createContext 'plain'
  local Reader = ui.component('Reader', function()
    return element('test/text', { key = 'reader', text = ui.useContext(Theme) })
  end)
  local flavour = ui.store 'plain'
  local Root = ui.component('Root', function()
    return element('test/column', { ui.provide(Theme, ui.useStore(flavour), Reader {}) })
  end)
  ui.mount(state.panel, Root {})
  state.fixture:step()
  expect.equal(label(state, 'reader'), 'plain')
  flavour:set 'fancy'
  state.fixture:step()
  expect.equal(label(state, 'reader'), 'fancy')
  state.fixture:close()
end)

test('mapped children require unique keys', function()
  expect.raises(function()
    ui.map({ 1, 2 }, function(value)
      return element('test/leaf', { key = 'same' })
    end)
  end, 'share the key')
  expect.raises(function()
    ui.map({ 1 }, function()
      return element('test/leaf', {})
    end)
  end, 'has no key')
end)

return test
