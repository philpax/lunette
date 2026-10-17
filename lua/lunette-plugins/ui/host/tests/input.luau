local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require '@testing/ui-host'
local input = require '../private/input'
local expect = testing.expect
local test = testing.suite()

local function boot(): (fixture.State, { any })
  local events = {}
  local state = fixture.boot {
    width = 0.3,
    height = 0.2,
    setup = function(service, owner)
      service:registerKind(owner, {
        name = 'test/drag',
        layout = {
          kind = 'container',
          style = function()
            return { width = 0.2, height = 0.1 }
          end,
        },
        claims = { drag = 'x' },
        interactive = function()
          return true
        end,
        event = function(_node, event)
          table.insert(events, event)
        end,
      })
    end,
  }
  fixture.show(state, uiHost.element('test/drag', { key = 'drag' }))
  return state, events
end

local function moves(events): { any }
  local result = {}
  for _, event in events do
    if event.kind == 'drag' then
      table.insert(result, event)
    end
  end
  return result
end

test('a primary capture advances once per sample while hover and another button also move', function()
  local state, events = boot()
  local controls = state.fixture
  local geometry = fixture.geometry(state)
  controls:aim(geometry, 0.04, 0.04)
  controls:step()
  controls:button('right', 'trigger', true)
  controls:step()
  table.clear(events)
  controls:aim(geometry, 0.06, 0.04)
  controls:step()
  expect.equal(#moves(events), 1, 'one captured drag per sample')
  local interaction = require '@lunette-contracts/interaction'
  local observed = assert(controls.session):observe(interaction.capability)
  local pointer = assert(observed.service):newPointer(assert(observed.context))
  local surface = fixture.surface(state)
  local function update(at, held)
    local pose = geometry.pose
    local x, y, z = pose:mul(at - geometry.width / 2, geometry.height / 2 - 0.04, 1)
    pointer:update(
      { origin = vector.pack(x, y, z), direction = vector.pack(0, 0, -1), buttons = held, grip = false },
      { surface }
    )
  end
  controls:button('right', 'trigger', false)
  controls:step()
  update(0.04, { left = true, right = true })
  table.clear(events)
  update(0.06, { left = true, right = true })
  expect.equal(#moves(events), 1, 'secondary capture does not advance the primary gesture')
  state.fixture:close()
end)

test('hover over another panel never supplies coordinates to the original capture', function()
  local state, events = boot()
  local other = state.service:newPanel(state.owner, {
    name = 'other',
    width = 0.3,
    height = 0.2,
    pose = lovr.math.newMat4():translate(0.5, 1.5, -1),
  })
  other.root:bind {
    render = function()
      other.root:submit(uiHost.element('test/drag', {}))
    end,
  }
  state.fixture:step()
  local interaction = require '@lunette-contracts/interaction'
  local observed = assert(state.fixture.session):observe(interaction.capability)
  local surfaces = require '@lunette-contracts/surfaces'
  local offers = assert(assert(state.fixture.session):observe(surfaces.capability).service)
  local pointer = assert(observed.service):newPointer(assert(observed.context))
  local function update(x)
    pointer:update(
      { origin = vector.pack(x, 1.56, 0), direction = vector.pack(0, 0, -1), buttons = { left = true }, grip = false },
      offers:all()
    )
  end
  update(-0.11)
  table.clear(events)
  update(0.39)
  local dragged = moves(events)
  expect.equal(#dragged, 1, 'only the original panel projects captured motion')
  expect.near(dragged[1].x, 0.54, 1e-6, 'coordinates stay in the original panel')
  state.fixture:close()
end)

test('fully idle pointer records are forgotten without losing reentrant input', function()
  local router = input.new()
  local panel = { root = nil }
  local env = {}
  for _ = 1, 30 do
    local pointer = { source = 'touch' }
    input.pointer(router, panel, env, { kind = 'enter', pointer = pointer, x = 0, y = 0 })
    input.pointer(router, panel, env, { kind = 'leave', pointer = pointer })
  end
  expect.equal(next(router.pointers), nil, 'idle devices are not retained')
  local pointer = { source = 'touch' }
  local node = {
    dead = false,
    state = {},
    liftTarget = 0,
    host = { hovers = 1 },
    kind = { registration = {} },
    handle = { theme = { elevation = {} } },
  }
  local state = { pointer = pointer, generation = 0, hovered = node }
  router.pointers[pointer] = state
  env.protect = function(_label, run)
    run()
    return true
  end
  node.kind.registration.event = function()
    router.pointers[pointer] = { pointer = pointer, generation = 0, handoff = panel }
  end
  input.pointer(router, panel, env, { kind = 'leave', pointer = pointer })
  expect.truthy(router.pointers[pointer].handoff, 'a callback-created record survives pruning')
  router.pointers[pointer] = { pointer = pointer, generation = 0, hovered = node }
  input.removed(router, node)
  expect.equal(next(router.pointers), nil, 'removing the final hovered node forgets its idle pointer')
end)

local function callbackPointer(hooks)
  local router
  local create = input.new
  input.new = function()
    router = create()
    return router
  end
  local log = {}
  local ok, state = pcall(fixture.boot, {
    width = 0.3,
    height = 0.2,
    setup = function(service, owner)
      service:registerKind(owner, {
        name = 'test/row',
        layout = {
          kind = 'container',
          style = function()
            return { width = 0.2, height = 0.1, flexDirection = 'row' }
          end,
        },
      })
      service:registerKind(owner, {
        name = 'test/callback',
        layout = {
          kind = 'container',
          style = function()
            return { width = 0.1, height = 0.1 }
          end,
        },
        claims = if hooks.drag then { drag = 'x' } else nil,
        interactive = function(props)
          if hooks.interactive then
            hooks.interactive(props)
          end
          return true
        end,
        event = function(node, event)
          table.insert(log, `{node.key}:{event.kind}`)
          if event.kind == 'activate' then
            node:emit 'onActivate'
          end
          if hooks.event then
            hooks.event(node, event)
          end
        end,
      })
    end,
  })
  input.new = create
  assert(ok, state)
  fixture.show(
    state,
    uiHost.element('test/row', {
      uiHost.element('test/callback', { key = 'first', onActivate = hooks.activate }),
      uiHost.element('test/callback', { key = 'second' }),
    })
  )
  local observed = assert(state.fixture.session):observe(require('@lunette-contracts/interaction').capability)
  local pointer = assert(observed.service):newPointer(assert(observed.context))
  local surface = fixture.surface(state)
  local geometry = fixture.geometry(state)
  local function update(x, down)
    local px, py, pz = geometry.pose:mul(x - geometry.width / 2, geometry.height / 2 - 0.04, 1)
    pointer:update({
      origin = vector.pack(px, py, pz),
      direction = vector.pack(0, 0, -1),
      buttons = { left = down == true },
      grip = false,
    }, { surface })
  end
  return state, pointer, assert(router), log, update
end

test('activation withdrawal cannot restore detached hover and later hover stays balanced', function()
  local pointer
  local state, device, router, log, update = callbackPointer {
    activate = function()
      pointer:withdraw()
    end,
  }
  pointer = device
  local node = assert(state.panel:find 'first')
  update(0.04, false)
  update(0.04, true)
  update(0.04, false)
  expect.falsy(node.state.hovered, 'activation withdrawal leaves no highlight')
  expect.equal(router.pointers[pointer], nil, 'activation withdrawal forgets the pointer record')
  table.clear(log)
  update(0.04, false)
  pointer:hover(nil)
  expect.equal(table.concat(log, ','), 'first:hover-enter,first:hover-leave', 'later hover is balanced')
  expect.falsy(node.state.hovered, 'later leave clears the highlight')
  expect.equal(router.pointers[pointer], nil, 'later leave forgets its record')
  state.fixture:close()
end)

test('interactive hover clearing supersedes initial enter without recreating hover', function()
  local pointer
  local clearing = true
  local state, device, router, log, update = callbackPointer {
    interactive = function()
      if pointer and clearing then
        clearing = false
        pointer:hover(nil)
      end
    end,
  }
  pointer = device
  update(0.04, false)
  expect.equal(router.pointers[pointer], nil, 'nested leave forgets the initial record')
  expect.falsy(assert(state.panel:find 'first').state.hovered, 'stale enter does not highlight')
  expect.equal(#log, 0, 'stale enter dispatches no hover')
  update(0.04, false)
  pointer:hover(nil)
  expect.equal(table.concat(log, ','), 'first:hover-enter,first:hover-leave', 'later hover is balanced')
  state.fixture:close()
end)

test('hover-leave clearing cannot highlight the next target on the resumed move', function()
  local pointer
  local state, device, router, log, update = callbackPointer {
    event = function(node, event)
      if node.key == 'first' and event.kind == 'hover-leave' then
        pointer:hover(nil)
      end
    end,
  }
  pointer = device
  update(0.04, false)
  table.clear(log)
  update(0.14, false)
  expect.falsy(assert(state.panel:find 'first').state.hovered, 'previous target leaves hover')
  expect.falsy(assert(state.panel:find 'second').state.hovered, 'next target is not highlighted after clearing')
  expect.equal(router.pointers[pointer], nil, 'nested leave clears the routing record')
  expect.equal(table.concat(log, ','), 'first:hover-leave', 'an unentered target receives no hover events')
  state.fixture:close()
end)

test('drag-start withdrawal stops drag delivery and leaves no hover or capture', function()
  local pointer
  local state, device, router, log, update = callbackPointer {
    drag = true,
    event = function(_node, event)
      if event.kind == 'drag-start' then
        pointer:withdraw()
      end
    end,
  }
  pointer = device
  update(0.04, false)
  update(0.04, true)
  table.clear(log)
  update(0.06, true)
  expect.equal(table.concat(log, ','), 'first:drag-start,first:cancel,first:hover-leave', 'withdrawal stops drag')
  local node = assert(state.panel:find 'first')
  expect.falsy(node.state.hovered, 'withdrawal clears hover')
  expect.falsy(node.state.pressed, 'withdrawal clears press')
  expect.falsy(node.state.dragging, 'withdrawal clears dragging')
  expect.equal(router.pointers[pointer], nil, 'withdrawal forgets the pointer record')
  state.fixture:close()
end)

test('nested leave during drag-start supersedes movement while retaining the capture', function()
  local pointer
  local state, device, router, log, update = callbackPointer {
    drag = true,
    event = function(_node, event)
      if event.kind == 'drag-start' then
        pointer:hover(nil)
      end
    end,
  }
  pointer = device
  update(0.04, false)
  update(0.04, true)
  local record = assert(router.pointers[pointer])
  table.clear(log)
  update(0.06, true)
  expect.equal(router.pointers[pointer], record, 'captured leave retains the same record')
  expect.truthy(record.capture, 'captured leave retains the gesture')
  expect.equal(table.concat(log, ','), 'first:drag-start', 'superseded movement stops before drag')
  table.clear(log)
  update(0.08, true)
  expect.equal(table.concat(log, ','), 'first:drag', 'the next sample continues the capture')
  pointer:withdraw()
  expect.falsy(assert(state.panel:find 'first').state.hovered, 'later withdrawal clears hover')
  expect.equal(router.pointers[pointer], nil, 'later withdrawal clears the record')
  state.fixture:close()
end)

test('interactive hover clearing on release cannot strand a completed capture', function()
  local pointer
  local clearing = false
  local state, device, router, _log, update = callbackPointer {
    interactive = function()
      if pointer and clearing then
        clearing = false
        pointer:hover(nil)
      end
    end,
  }
  pointer = device
  update(0.04, false)
  update(0.04, true)
  clearing = true
  pointer:setButton { button = 'left', pressed = false, x = 0.04, y = 0.04 }
  local node = assert(state.panel:find 'first')
  expect.falsy(node.state.pressed, 'completed release clears press before the predicate')
  expect.falsy(node.state.hovered, 'nested leave clears released hover')
  expect.equal(router.pointers[pointer], nil, 'completed capture cannot remain after nested leave')
  state.fixture:close()
end)

return test
