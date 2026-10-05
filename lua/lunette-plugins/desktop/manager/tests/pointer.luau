local testing = require '@testing'
local plugin = require '@lunette-plugin'
local interactionContract = require '@lunette-contracts/interaction'
local interaction = require '@lunette-plugins/interaction'
local drops = require '@lunette-plugins/drops'
local focus = require '@lunette-plugins/focus'
local controller = require '@lunette-plugins/desktop/manager/controller'
local boot = require './support/boot'
local expect = testing.expect
local suite = testing.suite()
local fixtures = {}

local function test(name, run)
  suite(name, function()
    fixtures = {}
    local ok, problem = pcall(run)
    local failures = {}
    if not ok then
      failures[#failures + 1] = tostring(problem)
    end
    for index = #fixtures, 1, -1 do
      local closed, failure = pcall(fixtures[index].close, fixtures[index])
      if not closed then
        failures[#failures + 1] = 'fixture cleanup: ' .. tostring(failure)
      end
    end
    fixtures = {}
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end)
end

local function fixture()
  local service, owner
  local observer = plugin.define {
    name = 'pointer-observer',
    requires = { interaction = interactionContract.capability },
    init = function(context)
      service, owner = context:require(interactionContract.capability), context
    end,
  }
  local running, fake, all, state = boot({ visible = true }, {
    { id = 'drops', definition = drops.definition },
    { id = 'focus', definition = focus.definition },
    { id = 'interaction', definition = interaction.definition },
    { id = 'pointer-observer', definition = observer },
  }, { 'frame', 'surfaces' })
  local f = { running = running, fake = fake, all = all, state = state, surface = all()[1], events = {} }
  fixtures[#fixtures + 1] = f
  function f:matching(kind, pointer, button)
    local result = {}
    for _, recorded in self.events do
      local event = recorded.event
      if
        event.kind == kind
        and (not pointer or event.pointer == pointer)
        and (not button or event.button == button)
      then
        result[#result + 1] = recorded
      end
    end
    return result
  end
  function f:pointer()
    return service:newPointer(owner, { tuning = { scrollScale = 36 } })
  end
  function f:update(pointer, x, y, fields)
    fields = fields or {}
    local offered = self.surface
    local origin = vector.pack(
      offered.pose:mul((x / state.width - 0.5) * offered.width, (0.5 - y / state.height) * offered.height, 1, 1)
    )
    local direction = fields.direction or vector.pack(offered.pose:mul(0, 0, -1, 0))
    pointer:update({
      origin = origin,
      direction = direction,
      pose = fields.pose or lovr.math.newMat4(),
      buttons = fields.buttons or {},
      grip = fields.grip or false,
      scrollX = fields.scrollX,
      scrollY = fields.scrollY,
      dt = fields.dt or 1,
    }, self.all())
  end
  function f:close()
    if self.closed then
      return
    end
    self.running.runtime:close()
    self.closed = true
    self.fake.assertResourcesReleased()
  end
  local handler = f.surface.onPointer
  f.surface.onPointer = function(self, event)
    f.events[#f.events + 1] = { surface = self, event = event, dragging = f.state.view.dragging }
    return handler(self, event)
  end
  return f
end

local function nodePoint(state)
  for _, box in state.view.layout do
    local camera = state.view.camera
    local x = (box.x + box.width / 2 - camera.x) * camera.zoom
    local y = (box.y + box.height / 2 - camera.y) * camera.zoom
    if x > 0 and x < state.view.viewport.x and y > 0 and y < state.view.viewport.y then
      return x, y
    end
  end
  error('the manager fixture has no visible graph node', 0)
end

test('a real secondary pointer press cannot activate a manager action or start a graph gesture', function()
  local f = fixture()
  local pointer = f:pointer()
  local catalog
  for _, button in f.state.buttons do
    if button.label == 'Catalog' then
      catalog = button
    end
  end
  expect.truthy(catalog, 'the catalog action exists')
  f:update(pointer, catalog.x + 1, catalog.y + 1, { buttons = { right = true } })
  expect.equal(f.state.tab, 'inspect', 'secondary press does not activate the action')
  f:update(pointer, 1, 1)
  f:update(pointer, 1, 1, { buttons = { right = true } })
  expect.equal(f.state.view.dragging, nil, 'secondary press does not capture the graph')
  f:update(pointer, 1, 1)
  f:update(pointer, 1, 1, { buttons = { left = true } })
  local gesture = f.state.view.dragging
  f:update(pointer, 1, 1, { buttons = { left = true, right = true } })
  f:update(pointer, 1, 1, { buttons = { left = true } })
  expect.equal(f.state.view.dragging, gesture, 'secondary release does not end primary capture')
  f:close()
end)

test('tracking loss cancels a real manager click without selecting a node on release or reacquisition', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = nodePoint(f.state)
  f:update(pointer, x, y, { buttons = { left = true } })
  expect.truthy(f.state.view.dragging, 'the primary press is pending')
  pointer:withdraw()
  expect.equal(f.state.view.dragging, nil, 'tracking loss clears the gesture')
  expect.equal(f.state.view.selection, nil, 'tracking loss does not click the node')
  f:update(pointer, x, y, { buttons = { left = true } })
  expect.equal(f.state.view.dragging, nil, 'held reacquisition cannot press again')
  f:update(pointer, x, y)
  expect.equal(f.state.view.selection, nil, 'the held release is not a click')
  f:update(pointer, x, y, { buttons = { left = true } })
  f:update(pointer, x, y)
  expect.truthy(f.state.view.selection, 'a fresh press and release can select the node')
  f:close()
end)

test('a real captured manager drag projects beyond hover bounds and releases at the projected position', function()
  local f = fixture()
  local pointer = f:pointer()
  local camera = f.state.view.camera
  f:update(pointer, 1, 1, { buttons = { left = true } })
  f:update(pointer, -39, 31, { buttons = { left = true } })
  local moved = f.state.view.camera
  expect.equal(pointer.hovered, nil, 'the ray leaves bounded hover')
  expect.truthy(f.state.view.dragging, 'hover leave preserves capture')
  expect.near((camera.x - moved.x) * camera.zoom, -40, 1e-3, 'projected drag pans outside x')
  expect.near((camera.y - moved.y) * camera.zoom, 30, 1e-3, 'projected drag pans outside y')
  f:update(pointer, -49, 41)
  local released = f.state.view.camera
  expect.equal(f.state.view.dragging, nil, 'release ends the projected drag')
  expect.near((moved.x - released.x) * moved.zoom, -10, 1e-3, 'release uses projected x')
  expect.near((moved.y - released.y) * moved.zoom, 10, 1e-3, 'release uses projected y')
  expect.equal(f.state.view.selection, nil, 'an outside drag cannot click a graph node')
  f:close()
end)

test('a real grip grab cancels the manager click before moving its pose', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = nodePoint(f.state)
  f:update(pointer, x, y, { buttons = { left = true } })
  local position = vector.pack(f.surface.pose:getPosition())
  local cancel, seen = controller.cancel, nil
  controller.cancel = function(state)
    if state == f.state then
      seen = vector.pack(f.surface.pose:getPosition())
    end
    return cancel(state)
  end
  local ok, problem = pcall(function()
    f:update(pointer, x, y, { buttons = { left = true }, grip = true })
    expect.equal(pointer.grabbed, f.surface, 'grip starts a real surface grab')
    expect.equal(f.state.view.dragging, nil, 'the graph click is cancelled')
    f:update(pointer, x, y, {
      buttons = { left = true },
      grip = true,
      pose = lovr.math.newMat4():translate(0.25, 0, 0),
    })
  end)
  controller.cancel = cancel
  if not ok then
    error(problem, 0)
  end
  expect.equal(seen, position, 'cancellation precedes pose movement')
  expect.truthy(vector.pack(f.surface.pose:getPosition()) ~= position, 'the grab moves the panel')
  expect.equal(f.state.view.selection, nil, 'grab cancellation never activates a graph click')
  f:close()
end)

test('manager hide and disposal call public cancellation immediately and retained callbacks stay inert', function()
  for _, action in { 'hide', 'dispose' } do
    local f = fixture()
    local pointer = f:pointer()
    f:update(pointer, 1, 1, { buttons = { left = true } })
    if action == 'hide' then
      lovr.keypressed('f10', 0, false)
    else
      f.running.service:disable 'desktop/manager'
    end
    local cancelled = f:matching('cancel', pointer, 'left')
    expect.equal(#cancelled, 1, 'cleanup delivers cancellation immediately and once')
    expect.equal(cancelled[1].surface, f.surface, 'the manager cancels its captured surface')
    expect.equal(cancelled[1].event.pointer, pointer, 'cancellation retains the real pointer identity')
    expect.equal(cancelled[1].event.reason, if action == 'hide' then 'hidden' else 'surface-dead', 'the cleanup reason')
    expect.equal(cancelled[1].dragging, nil, 'manager ownership and gesture are cleared before the callback')
    expect.equal(f.state.view.dragging, nil, 'cleanup leaves no manager gesture')
    local camera = f.state.view.camera
    f.surface:onPointer {
      kind = 'press',
      pointer = pointer,
      button = 'left',
      x = 1,
      y = 1,
      captured = true,
      inside = true,
    }
    expect.equal(f.state.view.dragging, nil, 'retained input cannot restart a hidden or dead gesture')
    if action == 'hide' then
      lovr.keypressed('f10', 0, false)
      f:update(pointer, 31, 31, { buttons = { left = true } })
      expect.equal(f.state.view.dragging, nil, 'held input cannot reacquire after hiding')
      expect.equal(f.state.view.camera, camera, 'held movement cannot resume the cancelled drag')
      f:update(pointer, 1, 1)
      f:update(pointer, 1, 1, { buttons = { left = true } })
      expect.truthy(f.state.view.dragging, 'an observed release permits a new press')
    end
    f:close()
  end
end)

test('manager cancel releases exclusive ownership before a controller callback can press another pointer', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  f:update(first, 1, 1, { buttons = { left = true } })
  local cancel = controller.cancel
  local entered = false
  controller.cancel = function(state)
    cancel(state)
    if state == f.state and not entered then
      entered = true
      f:update(second, 1, 1, { buttons = { left = true } })
    end
  end
  local ok, problem = pcall(function()
    first:cancel(f.surface, 'disabled')
  end)
  controller.cancel = cancel
  if not ok then
    error(problem, 0)
  end
  expect.truthy(entered, 'the cancellation callback runs')
  expect.truthy(f.state.view.dragging, 'another pointer can acquire the cleared manager ownership')
  f:update(second, 1, 1)
  expect.equal(f.state.view.dragging, nil, 'the replacement pointer owns the release')
  f:close()
end)

test('real outside toolbar release and invalid graph projection never call the manager click release', function()
  for _, target in { 'toolbar', 'graph' } do
    local f = fixture()
    local pointer = f:pointer()
    local x, y
    if target == 'graph' then
      x, y = nodePoint(f.state)
    else
      for _, button in f.state.buttons do
        if button.label == 'Catalog' then
          x, y = button.x + 1, button.y + 1
        end
      end
    end
    f:update(pointer, x, y, { buttons = { left = true } })
    local release, calls = controller.release, 0
    controller.release = function(state, point)
      calls += 1
      return release(state, point)
    end
    local ok, problem = pcall(function()
      if target == 'graph' then
        f:update(pointer, x, y, { direction = vector.pack(1, 0, 0) })
      else
        f:update(pointer, f.state.width + 10, y)
      end
    end)
    controller.release = release
    if not ok then
      error(problem, 0)
    end
    expect.equal(calls, 0, 'outside or invalid release cannot run the click release path')
    expect.equal(f.state.view.selection, nil, 'release cannot select a graph node')
    expect.equal(f.state.view.dragging, nil, 'release still ends the gesture')
    f:close()
  end
end)

test('an outside real release cancels a pending graph click even within the drag threshold', function()
  local f = fixture()
  local pointer = f:pointer()
  f:update(pointer, 1, 1, { buttons = { left = true } })
  expect.equal(f.state.view.dragging.kind, 'pending-click', 'the press has not become a drag')
  local release, calls = controller.release, 0
  controller.release = function(state, point)
    calls += 1
    return release(state, point)
  end
  local ok, problem = pcall(function()
    f:update(pointer, -1, 1)
  end)
  controller.release = release
  if not ok then
    error(problem, 0)
  end
  expect.equal(calls, 0, 'bounded leave cannot turn the pending press into a click')
  expect.equal(f.state.view.dragging, nil, 'the cancelled pending gesture ends')
  f:close()
end)

test(
  'hiding immediately cancels all real manager pointers including secondary and rejected primary captures',
  function()
    local f = fixture()
    local first, second = f:pointer(), f:pointer()
    f:update(first, 1, 1, { buttons = { left = true } })
    f:update(second, 1, 1, { buttons = { left = true, right = true } })
    lovr.keypressed('f10', 0, false)
    expect.equal(#f:matching('cancel', first, 'left'), 1, 'the exclusive graph owner is cancelled')
    expect.equal(#f:matching('cancel', second, 'left'), 1, 'the rejected primary capture is cancelled')
    expect.equal(#f:matching('cancel', second, 'right'), 1, 'the secondary capture is cancelled')
    local cancelled = f:matching 'cancel'
    expect.equal(#cancelled, 3, 'every delivered button capture is cancelled exactly once')
    for _, recorded in cancelled do
      expect.equal(recorded.event.reason, 'hidden', 'every delivered capture is hidden')
    end
    lovr.keypressed('f10', 0, false)
    f:update(second, 1, 1, { buttons = { left = true, right = true } })
    expect.equal(f.state.view.dragging, nil, 'held rejected capture cannot become a new graph press')
    f:close()
  end
)

test('manager hide attempts every real pointer cancellation even when a callback raises', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local handler = f.surface.onPointer
  f.surface.onPointer = function(self, event)
    handler(self, event)
    if event.kind == 'cancel' and event.reason == 'hidden' and event.pointer == first then
      error('injected manager cancellation failure', 0)
    end
  end
  f:update(first, 1, 1, { buttons = { left = true } })
  f:update(second, 1, 1, { buttons = { right = true } })
  lovr.keypressed('f10', 0, false)
  expect.equal(#f:matching('cancel', first, 'left'), 1, 'the failing cancellation is delivered')
  expect.equal(#f:matching('cancel', second, 'right'), 1, 'another pointer is cancelled despite the failure')
  expect.equal(#f:matching 'cancel', 2, 'both cancellations are delivered exactly once')
  expect.equal(f.state.view.dragging, nil, 'ownership and the gesture remain cleared')
  local reports = f.fake.events.reported
  expect.equal(#reports, 1, 'the frame boundary reports the cleanup error')
  expect.truthy(reports[1].message:find('injected manager cancellation failure', 1, true), 'the cause is retained')
  f:close()
end)

test('real pointer scrolling reuses manager graph zoom and detail row scrolling', function()
  local f = fixture()
  local pointer = f:pointer()
  local camera = f.state.view.camera
  local x, y = 100, 100
  local worldX, worldY = camera.x + x / camera.zoom, camera.y + y / camera.zoom
  f:update(pointer, x, y, { scrollY = 1 })
  local zoomed = f.state.view.camera
  expect.truthy(zoomed.zoom > camera.zoom, 'positive graph scroll zooms in')
  expect.near(zoomed.x + x / zoomed.zoom, worldX, 1e-4, 'zoom retains the pointed graph x')
  expect.near(zoomed.y + y / zoomed.zoom, worldY, 1e-4, 'zoom retains the pointed graph y')
  local before = f.state.scroll
  f:update(pointer, f.state.view.viewport.x + 10, f.state.bodyTop + 10, { scrollY = -1 })
  expect.truthy(f.state.scroll > before, 'negative detail scroll advances rows')
  f:update(pointer, f.state.view.viewport.x + 10, f.state.bodyTop + 10, { scrollY = 1 })
  expect.equal(f.state.scroll, before, 'opposite detail scroll restores the row offset')
  f:close()
end)

test('small real detail scroll deltas accumulate across frames instead of being rounded away', function()
  local f = fixture()
  local pointer = f:pointer()
  local before = f.state.scroll
  for _ = 1, 4 do
    f:update(pointer, f.state.view.viewport.x + 10, f.state.bodyTop + 10, { scrollY = -1, dt = 0.25 })
  end
  expect.equal(f.state.scroll, before + 1, 'four quarter-row samples advance one row')
  f:close()
end)

return suite
