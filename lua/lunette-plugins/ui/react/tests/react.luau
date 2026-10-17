local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local ui = require '@lunette-plugins/ui/react'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local function boot(): fixture.State
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
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
  local Counter = ui.component('Counter', function(): any
    local count, setCount = ui.useState(0)
    return element('test/column', {
      padding = 0.01,
      element('test/button', {
        key = 'go',
        onActivate = function()
          setCount(function(current: number): number
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

test('effects run after the render pass and clean up on unmount', function()
  local state = boot()
  local log: { string } = {}
  local Effectful = ui.component('Effectful', function(props: { value: number }): any
    ui.useEffect(function(): (() -> ())?
      table.insert(log, `run {props.value}`)
      return function()
        table.insert(log, `clean {props.value}`)
      end
    end, { props.value })
    return element('test/leaf', { width = 0.01, height = 0.01 })
  end)
  local value = ui.store(1)
  local Root = ui.component('Root', function(): any
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

test('mapped children require unique keys', function()
  expect.raises(function()
    ui.map({ 1, 2 }, function(value: number): any
      return element('test/leaf', { key = 'same' })
    end)
  end, 'share the key')
  expect.raises(function()
    ui.map({ 1 }, function(): any
      return element('test/leaf', {})
    end)
  end, 'has no key')
end)

test('a child that is not rendered again calls the newest callback of its parent', function()
  local state = boot()
  local childRenders = 0
  local Child = ui.component('Child', function(props: { onPress: () -> () }): any
    childRenders += 1
    return element(
      'test/button',
      { key = 'go', onActivate = props.onPress, element('test/leaf', { width = 0.04, height = 0.02 }) }
    )
  end)
  local Parent = ui.component('Parent', function(): any
    local count, setCount = ui.useState(0)
    return element('test/column', {
      padding = 0.01,
      element('test/text', { key = 'count', text = tostring(count) }),
      Child {
        key = 'child',
        onPress = function()
          setCount(count + 1)
        end,
      },
    })
  end)
  ui.mount(state.panel, Parent {})
  state.fixture:step()
  for _ = 1, 3 do
    fixture.click(state, 'go')
    state.fixture:step()
  end
  expect.equal(label(state, 'count'), '3', 'each press counts from the latest state')
  expect.equal(childRenders, 1, 'the child rendered once')
  state.fixture:close()
end)

test('a failed render keeps state working and discards its effects', function()
  local state = boot()
  local failing = false
  local effects = 0
  local setValue: ((number) -> ())? = nil
  local Flaky = ui.component('Flaky', function(): any
    local value, set = ui.useState(0)
    setValue = set
    ui.useEffect(function(): (() -> ())?
      effects += 1
      return nil
    end, { value })
    if failing then
      error 'deliberate render failure'
    end
    return element('test/column', { element('test/text', { key = 'value', text = tostring(value) }) })
  end)
  ui.mount(state.panel, Flaky {})
  state.fixture:step()
  expect.equal(effects, 1)
  failing = true
  assert(setValue)(1)
  state.fixture:step()
  local reported = state.fixture.native.events.reported
  expect.truthy(
    #reported > 0 and string.find(reported[#reported].message, 'deliberate render failure', 1, true),
    'the failure is reported'
  )
  table.clear(reported)
  expect.equal(effects, 1, 'the failed render ran no effect')
  expect.equal(label(state, 'value'), '0', 'the previous output stays')
  failing = false
  assert(setValue)(2)
  state.fixture:step()
  expect.equal(label(state, 'value'), '2', 'state set after the failure applies')
  expect.equal(effects, 2)
  state.fixture:close()
end)

return test
