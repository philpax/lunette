local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require './support/host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

-- A column, a fixed-size leaf, a text label, a pressable box, and a composite counter.
local function register(service: uiHost.Service, owner: any, log: { string }): ()
  service:registerKind(owner, {
    name = 'test/column',
    layout = {
      kind = 'container',
      style = function(props)
        return { flexDirection = 'column', padding = props.padding or 0, gap = props.gap or 0 }
      end,
    },
  })
  service:registerKind(owner, {
    name = 'test/leaf',
    layout = {
      kind = 'leaf',
      style = function(props)
        return { width = props.width, height = props.height }
      end,
    },
  })
  service:registerKind(owner, {
    name = 'test/text',
    layout = {
      kind = 'text',
      text = function(props)
        return props.text
      end,
      textStyle = function(_props, theme)
        local body = theme.type.body
        return { family = body.family, size = body.size, weight = body.weight }
      end,
    },
  })
  service:registerKind(owner, {
    name = 'test/button',
    layout = {
      kind = 'container',
      style = function()
        return { padding = 0.004 }
      end,
    },
    response = { lift = true, travel = true },
    elevation = 'raised',
    event = function(node, event, base)
      table.insert(log, `{node.key or '?'}:{event.kind}`)
      if event.kind == 'activate' then
        node:emit 'onActivate'
      elseif event.kind ~= 'hover-enter' and event.kind ~= 'hover-leave' then
        base(node, event)
      end
    end,
  })
  service:registerKind(owner, {
    name = 'test/counter',
    state = { count = 0 },
    expand = function(_props, _children, state, actions)
      return {
        element('test/button', {
          key = 'increment',
          onActivate = function()
            actions.setState(function(current)
              return { count = current.count + 1 }
            end)
          end,
          element('test/text', { key = 'label', text = `count {state.count}` }),
        }),
      }
    end,
  })
end

local function near(actual: number, expected: number, label: string): ()
  expect.near(actual, expected, 1e-6, label)
end

test('a content-sized panel takes the size of its laid-out content', function()
  local log = {}
  local state = fixture.boot {
    setup = function(service, owner)
      register(service, owner, log)
    end,
  }
  fixture.show(
    state,
    element('test/column', {
      padding = 0.01,
      gap = 0.004,
      element('test/leaf', { key = 'first', width = 0.05, height = 0.02 }),
      element('test/leaf', { key = 'second', width = 0.03, height = 0.01 }),
    })
  )
  local width, height = state.panel:size()
  near(width, 0.07, 'the width is the widest child plus padding')
  near(height, 0.02 + 0.004 + 0.01 + 0.02, 'the height stacks the children with the gap')
  local second = assert(state.panel:find 'second')
  local bounds = second:panelBounds()
  near(bounds.y, 0.01 + 0.02 + 0.004, 'the second leaf follows the first')
  near(second.bounds.width, 0.03, 'the handle reports its own size')
  state.fixture:close()
end)

test('a nil child keeps the positions of the children after it', function()
  local state = fixture.boot {
    setup = function(service, owner)
      register(service, owner, {})
    end,
  }
  local function tree(withFirst: boolean)
    return element('test/column', {
      if withFirst then element('test/leaf', { width = 0.01, height = 0.01 }) else nil,
      element('test/leaf', { width = 0.02, height = 0.02 }),
    })
  end
  fixture.show(state, tree(true))
  local before = assert(state.panel:find '#2')
  fixture.show(state, tree(false))
  local after = assert(state.panel:find '#2')
  expect.equal(after, before, 'the second child keeps its node')
  expect.equal(state.panel:find '#1', nil, 'the first child is removed')
  state.fixture:close()
end)

test('a click hovers, presses, and activates the node under the ray', function()
  local log = {}
  local activations = 0
  local state = fixture.boot {
    setup = function(service, owner)
      register(service, owner, log)
    end,
  }
  fixture.show(
    state,
    element('test/column', {
      padding = 0.01,
      element('test/button', {
        key = 'go',
        onActivate = function()
          activations += 1
        end,
        element('test/leaf', { width = 0.04, height = 0.02 }),
      }),
    })
  )
  fixture.click(state, 'go')
  expect.equal(activations, 1, 'one activation')
  local sequence = table.concat(log, ' ')
  expect.truthy(string.find(sequence, 'go:hover-enter go:press go:release go:activate', 1, true), sequence)
  state.fixture:close()
end)

test('a composite re-expands when its state changes', function()
  local state = fixture.boot {
    setup = function(service, owner)
      register(service, owner, {})
    end,
  }
  fixture.show(state, element('test/column', { padding = 0.01, element('test/counter', { key = 'counter' }) }))
  local label = assert(state.panel:find 'counter/increment/label')
  expect.equal(label.props.text, 'count 0')
  fixture.click(state, 'counter/increment')
  state.fixture:step()
  local after = assert(state.panel:find 'counter/increment/label')
  expect.equal(after, label, 'the label node is kept')
  expect.equal(after.props.text, 'count 1')
  state.fixture:close()
end)

return test
