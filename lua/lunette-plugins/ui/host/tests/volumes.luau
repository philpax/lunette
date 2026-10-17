local testing = require '@testing'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local element = uiHost.element

type Seen = { volume: uiHost.Volume }

-- A leaf of the size it is given whose volume plants a plane at its base and records where the pass put it.
local function register(service: uiHost.Service, owner: any, seen: { Seen }, fail: { value: boolean }): ()
  fixture.registerKinds(service, owner, {})
  service:registerKind(owner, {
    name = 'test/volume',
    layout = {
      kind = 'leaf',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { width = props.width, height = props.height }
      end,
    },
    visuals = { 'test/volume' },
  })
  service:registerVisual(owner, 'test/volume', function(node: uiHost.Node, draw: uiHost.Draw)
    draw:volume(nil, {
      depth = 0.03,
      offset = node.props.offset,
      draw = function(pass: Pass, volume: uiHost.Volume): ()
        if fail.value then
          error('deliberate volume failure', 0)
        end
        pass:setColor(1, 0, 0, 1)
        pass:plane(0, 0, 0)
        table.insert(seen, { volume = volume })
      end,
    })
  end)
  service:registerKind(owner, {
    name = 'test/window',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { display = 'block', height = props.height, overflow = 'scroll' }
      end,
    },
    clip = true,
    state = { scrollY = 0 },
  })
end

-- The plane each volume drew in the last draw, as the recorded calls hold it.
local function planes(state: fixture.State): { any }
  local found = {}
  for _, call in state.fixture.native.events.draw do
    if call[1] == 'plane' then
      table.insert(found, call)
    end
  end
  return found
end

local function draw(state: fixture.State): { any }
  table.clear(state.fixture.native.events.draw)
  state.fixture:draw()
  return planes(state)
end

test("a volume's pass sits at the centre of its node's surface, lifted by its offset, every frame", function()
  local seen: { Seen } = {}
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      register(service, owner, seen, { value = false })
    end,
  }
  fixture.show(
    state,
    element('test/column', {
      padding = 0.01,
      element('test/volume', { key = 'volume', width = 0.04, height = 0.02, offset = 0.005 }),
    })
  )
  local drawn = draw(state)
  expect.equal(#drawn, 1, 'the volume draws')
  local node = assert(state.panel:find 'volume')
  local surface = node:pose()
  local expected = vector.pack(lovr.math.mat4(surface):translate(0, 0, 0.005):getPosition())
  local actual = vector.pack(lovr.math.mat4(drawn[1].transform):getPosition())
  expect.near(vector.magnitude(actual - expected), 0, 1e-6, 'the base centre')
  local facing = vector.pack(lovr.math.mat4(drawn[1].transform):mul(0, 0, 1, 0))
  local out = vector.pack(lovr.math.mat4(surface):mul(0, 0, 1, 0))
  expect.near(vector.dot(facing, out), 1, 1e-6, 'z points out of the panel')
  local volume = seen[#seen].volume
  expect.near(volume.width, 0.04, 1e-9)
  expect.near(volume.height, 0.02, 1e-9)
  expect.equal(volume.depth, 0.03)
  expect.equal(volume.opacity, 1)
  expect.equal(volume.scrim, 0)
  expect.equal(#draw(state), 1, 'the volume draws again without its node changing')
  expect.equal(#seen, 2)
  state.fixture:close()
end)

test('a volume on a curved panel sits on the curve, turned to its tangent', function()
  local seen: { Seen } = {}
  local curved: uiHost.Panel? = nil
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      register(service, owner, seen, { value = false })
      local panel = service:newPanel(owner, {
        name = 'curved',
        pose = lovr.math.newMat4():translate(0, 1.5, -1),
        width = 0.6,
        height = 0.2,
        curve = 2,
      })
      panel.root:bind {
        render = function()
          panel.root:submit(element('test/column', {
            padding = 0.01,
            element('test/volume', { key = 'volume', width = 0.05, height = 0.05 }),
          }))
        end,
      }
      curved = panel
    end,
  }
  local panel = assert(curved)
  panel.root:schedule()
  state.fixture:step()
  local drawn = draw(state)
  expect.equal(#drawn, 1)
  local surface = assert(panel:find 'volume'):pose()
  local actual = lovr.math.mat4(drawn[1].transform)
  expect.near(
    vector.magnitude(vector.pack(actual:getPosition()) - vector.pack(surface:getPosition())),
    0,
    1e-6,
    'the base centre lies on the curve'
  )
  local facing = vector.pack(actual:mul(0, 0, 1, 0))
  local out = vector.pack(lovr.math.mat4(surface):mul(0, 0, 1, 0))
  expect.near(vector.dot(facing, out), 1, 1e-6, 'z follows the curve normal')
  local base = vector.pack(lovr.math.mat4(panel:pose()):mul(0, 0, 1, 0))
  expect.truthy(vector.dot(facing, base) < 0.999, 'the left-hand node is turned from the panel normal')
  state.fixture:close()
end)

test('a volume partly scrolled out of view is hidden whole', function()
  local seen: { Seen } = {}
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      register(service, owner, seen, { value = false })
    end,
  }
  fixture.show(
    state,
    element('test/column', {
      element('test/window', {
        key = 'window',
        height = 0.05,
        element('test/volume', { key = 'first', width = 0.04, height = 0.03 }),
        element('test/volume', { key = 'second', width = 0.04, height = 0.03 }),
      }),
    })
  )
  expect.equal(#draw(state), 1, 'only the volume wholly inside the window draws')
  local window = assert(state.panel:find 'window')
  window:scrollTo(0.03)
  state.fixture:step()
  expect.equal(#draw(state), 1, 'the second volume, now whole, draws instead of the first')
  state.fixture:close()
end)

test('a volume that raises is reported once and the pass is restored', function()
  local seen: { Seen } = {}
  local fail = { value = true }
  local state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      register(service, owner, seen, fail)
    end,
  }
  fixture.show(state, element('test/volume', { key = 'volume', width = 0.04, height = 0.02 }))
  local reported = state.fixture.native.events.reported
  table.clear(reported)
  draw(state)
  draw(state)
  local failures = 0
  for _, report in reported do
    if string.find(report.message, 'deliberate volume failure', 1, true) then
      failures += 1
    end
  end
  expect.equal(failures, 1, 'the failure is reported once')
  fail.value = false
  fixture.show(state, element('test/volume', { key = 'volume', width = 0.05, height = 0.02 }))
  expect.equal(#draw(state), 1, 'the volume draws again once its visual runs again')
  state.fixture:close()
end)

return test
