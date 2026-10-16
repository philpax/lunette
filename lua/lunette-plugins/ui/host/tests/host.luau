local testing = require '@testing'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

local function near(actual: number, expected: number, label: string): ()
  expect.near(actual, expected, 1e-6, label)
end

test('a content-sized panel takes the size of its laid-out content', function()
  local log = {}
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, log)
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
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
    end,
  }
  local function tree(withFirst: boolean): uiHost.Element
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
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, log)
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
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
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

test('a tracked fingertip pushed into a node presses and activates it', function()
  local log: { string } = {}
  local activations = 0
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, log)
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
  local node = assert(state.panel:find 'go')
  local bounds = node:panelBounds()
  local width, height = state.panel:size()
  local pose = state.panel:pose()
  local raised = 0.003
  -- The skeleton stands in for a tracked bare hand: only the index fingertip, joint 11, is read.
  local tip = { 0, 0, 0, 0.005, 1, 0, 0, 0 }
  local skeleton = {}
  for joint = 1, 26 do
    skeleton[joint] = if joint == 11 then tip else { 0, 0, 0, 0.005, 1, 0, 0, 0 }
  end
  local headset = lovr.headset :: any
  headset.getSkeleton = function(device: string): { { number } }?
    return if device == 'hand/right' then skeleton else nil
  end
  state.fixture:tracked('right', true)
  for _, depth in { 0.06, 0.02, 0.008, -0.003, -0.005, 0.004 } do
    local x, y, z =
      pose:mul(bounds.x + bounds.width / 2 - width / 2, height / 2 - bounds.y - bounds.height / 2, raised + depth)
    tip[1], tip[2], tip[3] = x, y, z
    state.fixture:step()
  end
  headset.getSkeleton = nil
  expect.equal(activations, 1, `one activation: {table.concat(log, ' ')}`)
  state.fixture:close()
end)

local function pressable(log: { string }): (fixture.State, number, number)
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, log)
    end,
  }
  fixture.show(
    state,
    element('test/column', {
      padding = 0.01,
      element('test/button', {
        key = 'go',
        onActivate = function()
          table.insert(log, 'activated')
        end,
        element('test/leaf', { width = 0.04, height = 0.02 }),
      }),
    })
  )
  local bounds = assert(state.panel:find 'go'):panelBounds()
  return state, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2
end

local function deliver(surface: any, pointer: any, kind: string, x: number?, y: number?): ()
  surface:onPointer {
    kind = kind,
    pointer = pointer,
    x = x,
    y = y,
    button = 'left',
    captured = kind == 'release',
    inside = x ~= nil,
  }
end

test('a captured release without coordinates ends the capture outside the node', function()
  local log: { string } = {}
  local state, x, y = pressable(log)
  local surface = fixture.surface(state)
  local pointer = fixture.pointer()
  deliver(surface, pointer, 'enter', x, y)
  deliver(surface, pointer, 'press', x, y)
  deliver(surface, pointer, 'release', nil, nil)
  local node = assert(state.panel:find 'go')
  expect.falsy(node.state.pressed, 'the node is no longer pressed')
  expect.falsy(table.find(log, 'activated'), 'a release outside does not activate')
  deliver(surface, pointer, 'enter', x, y)
  deliver(surface, pointer, 'press', x, y)
  deliver(surface, pointer, 'release', x, y)
  expect.truthy(table.find(log, 'activated'), 'the pointer can press again')
  state.fixture:close()
end)

test('two pointers share hover, and only one captures a node', function()
  local log: { string } = {}
  local state, x, y = pressable(log)
  local surface = fixture.surface(state)
  local first, second = fixture.pointer(), fixture.pointer()
  deliver(surface, first, 'enter', x, y)
  deliver(surface, second, 'enter', x, y)
  deliver(surface, second, 'leave')
  local node = assert(state.panel:find 'go')
  expect.truthy(node.state.hovered, 'the first pointer still hovers')
  deliver(surface, first, 'press', x, y)
  deliver(surface, second, 'enter', x, y)
  deliver(surface, second, 'press', x, y)
  deliver(surface, second, 'release', x, y)
  deliver(surface, first, 'release', x, y)
  local activations = 0
  for _, entry in log do
    if entry == 'activated' then
      activations += 1
    end
  end
  expect.equal(activations, 1, 'one activation')
  state.fixture:close()
end)

test('nodes of a kind that registers late are made again with the registration', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
    end,
  }
  local tree = element('test/column', { element('test/late', { key = 'late' }) })
  fixture.show(state, tree)
  expect.equal(assert(state.panel:find 'late').kind, 'lunette/missing')
  local reported = state.fixture.native.events.reported
  expect.truthy(string.find(reported[#reported].message, 'test/late is not registered', 1, true))
  table.clear(reported)
  state.service:registerKind(state.owner, {
    name = 'test/late',
    layout = {
      kind = 'leaf',
      style = function(): lunette.LayoutStyle
        return { width = 0.01, height = 0.01 }
      end,
    },
  })
  state.fixture:step()
  expect.equal(assert(state.panel:find 'late').kind, 'test/late', 'the unchanged element now has its kind')
  state.fixture:close()
end)

test('a composite whose expansion fails keeps its children', function()
  local fail = false
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
      service:registerKind(owner, {
        name = 'test/fragile',
        expand = function(props: uiHost.Props): uiHost.Child
          if fail then
            error 'deliberate expansion failure'
          end
          return element('test/text', { key = 'kept', text = props.text })
        end,
      })
    end,
  }
  fixture.show(state, element('test/column', { element('test/fragile', { key = 'fragile', text = 'one' }) }))
  local kept = assert(state.panel:find 'fragile/kept')
  fail = true
  fixture.show(state, element('test/column', { element('test/fragile', { key = 'fragile', text = 'two' }) }))
  local reported = state.fixture.native.events.reported
  expect.truthy(string.find(reported[#reported].message, 'deliberate expansion failure', 1, true))
  table.clear(reported)
  expect.equal(state.panel:find 'fragile/kept', kept, 'the child survives the failure')
  fail = false
  fixture.show(state, element('test/column', { element('test/fragile', { key = 'fragile', text = 'three' }) }))
  expect.equal(state.panel:find 'fragile/kept', kept)
  expect.equal(kept.props.text, 'three')
  state.fixture:close()
end)

return test
