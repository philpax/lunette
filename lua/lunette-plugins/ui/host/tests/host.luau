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
      kind = 'container',
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

-- The scrim amounts that a draw of every panel sends, lowest first.
local function scrims(state: fixture.State): { number }
  table.clear(state.fixture.native.events.draw)
  state.fixture:draw()
  local amounts: { number } = {}
  for _, call in state.fixture.native.events.draw do
    if call[1] == 'send' and call[2] == 'panelScrim' then
      local value = call[3] :: any
      table.insert(amounts, value[4])
    end
  end
  table.sort(amounts)
  return amounts
end

test('nodes scrolled wholly outside a clip are not packed', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
      service:registerKind(owner, {
        name = 'test/window',
        layout = {
          kind = 'container',
          style = function(): lunette.LayoutStyle
            return { display = 'block', height = 0.05, overflow = 'scroll' }
          end,
        },
        clip = true,
      })
    end,
  }
  local swatches = {}
  for index = 1, 40 do
    swatches[index] = element('test/swatch', { key = `swatch-{index}` })
  end
  fixture.show(state, element('test/window', { key = 'window', swatches }))
  table.clear(state.fixture.native.events.draw)
  state.fixture:draw()
  local instances = 0
  for _, call in state.fixture.native.events.draw do
    if call[1] == 'draw' then
      instances += call[4] :: number
    end
  end
  -- Each swatch is 0.02 tall, so about three of the forty meet the 0.05 window.
  expect.truthy(instances > 0 and instances <= 4, `only the swatches in view are drawn: {instances}`)
  state.fixture:close()
end)

test('a panel that a dialog blocks draws under a scrim until the dialog closes', function()
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
    end,
  }
  fixture.show(state, element('test/swatch', {}))
  expect.equal(scrims(state)[1], 0, 'an unblocked panel draws clear')
  local dialog =
    state.service:newPanel(state.owner, { name = 'confirm', presentation = 'dialog', parent = state.panel })
  dialog.root:bind {
    render = function()
      dialog.root:submit(element('test/swatch', {}))
    end,
  }
  state.fixture:step()
  local open = scrims(state)
  expect.equal(#open, 2, 'both panels draw')
  expect.equal(open[1], 0, 'the dialog draws clear')
  expect.truthy(open[2] > 0, 'its parent draws under a scrim')
  dialog:destroy()
  state.fixture:step()
  local closed = scrims(state)
  expect.equal(closed[#closed], 0, 'the parent draws clear once the dialog closes')
  state.fixture:close()
end)

test('a dialog floats in front of its parent and blocks presses on it until it closes', function()
  local log: { string } = {}
  local state, x, y = pressable(log)
  local dialog = state.service:newPanel(state.owner, {
    name = 'confirm',
    presentation = 'dialog',
    parent = state.panel,
  })
  dialog.root:bind {
    render = function()
      dialog.root:submit(element('test/leaf', { width = 0.05, height = 0.03 }))
    end,
  }
  state.fixture:step()
  local parentPose, dialogPose = state.panel:pose(), dialog:pose()
  local _, _, parentZ = parentPose:getPosition()
  local _, _, dialogZ = dialogPose:getPosition()
  expect.near(dialogZ - parentZ, state.service:theme().elevation.dialog, 1e-6, 'the dialog stands in front')
  local surface = fixture.surface(state)
  local pointer = fixture.pointer()
  deliver(surface, pointer, 'enter', x, y)
  deliver(surface, pointer, 'press', x, y)
  deliver(surface, pointer, 'release', x, y)
  expect.falsy(table.find(log, 'activated'), 'the parent takes no press while the dialog is open')
  dialog:destroy()
  state.fixture:step()
  deliver(surface, pointer, 'press', x, y)
  deliver(surface, pointer, 'release', x, y)
  expect.truthy(table.find(log, 'activated'), 'the parent takes presses again')
  state.fixture:close()
end)

test('a kind with a props schema reports unknown and invalid props', function()
  local schema = require '@lunette-plugin/schema'
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
      service:registerKind(owner, {
        name = 'test/strict',
        props = schema.object { width = schema.number { positive = true } },
        layout = {
          kind = 'container',
          style = function(props: uiHost.Props): lunette.LayoutStyle
            return { width = props.width or 0.01, height = 0.01 }
          end,
        },
      })
    end,
  }
  local reported = state.fixture.native.events.reported
  fixture.show(state, element('test/column', { element('test/strict', { key = 'strict', width = 0.02 }) }))
  expect.equal(#reported, 0, 'valid props pass')
  fixture.show(state, element('test/column', { element('test/strict', { key = 'strict', widht = 0.02 }) }))
  expect.equal(#reported, 1, 'a misspelt prop is reported')
  expect.truthy(string.find(reported[1].message, 'widht', 1, true), reported[1].message)
  table.clear(reported)
  fixture.show(state, element('test/column', { element('test/strict', { key = 'strict', width = -1 }) }))
  expect.equal(#reported, 1, 'an invalid value is reported')
  table.clear(reported)
  expect.truthy(state.panel:find 'strict', 'the node still renders')
  state.fixture:close()
end)

test('a node near the edge of a curved panel is clicked where it is drawn', function()
  local log: { string } = {}
  local state = fixture.boot {
    width = 0.8,
    height = 0.2,
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, log)
    end,
  }
  state.panel:setCurve(1.5)
  fixture.show(
    state,
    element('test/column', {
      padding = 0.01,
      alignItems = 'end',
      element('test/button', {
        key = 'edge',
        onActivate = function()
          table.insert(log, 'activated')
        end,
        element('test/leaf', { width = 0.05, height = 0.03 }),
      }),
    })
  )
  fixture.click(state, 'edge')
  expect.truthy(table.find(log, 'activated'), 'the click lands on the bent node')
  state.fixture:close()
end)

test('a scroll reaches the node under the pointer with its position in that node', function()
  local received: { any } = {}
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, {})
      service:registerKind(owner, {
        name = 'test/canvas',
        layout = {
          kind = 'container',
          style = function(): any
            return { width = 0.1, height = 0.05 }
          end,
        },
        interactive = function(): boolean
          return true
        end,
        event = function(_node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
          if event.kind == 'scroll' then
            table.insert(received, event)
          else
            base(_node, event)
          end
        end,
      })
    end,
  }
  fixture.show(state, element('test/column', { padding = 0.01, element('test/canvas', { key = 'canvas' }) }))
  local surface = fixture.surface(state)
  local pointer = fixture.pointer()
  surface:onPointer { kind = 'move', pointer = pointer, x = 0.03, y = 0.02, inside = true, captured = false }
  surface:onPointer {
    kind = 'scroll',
    pointer = pointer,
    x = 0.03,
    y = 0.02,
    dx = 0,
    dy = 2,
    inside = true,
    captured = false,
  }
  expect.equal(#received, 1, 'the canvas receives the scroll')
  near(received[1].dy, 2, 'the scroll amount')
  near(received[1].x, 0.02, 'x is relative to the canvas')
  near(received[1].y, 0.01, 'y is relative to the canvas')
  state.fixture:close()
end)

return test
