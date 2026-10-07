local testing = require '@testing'
local controller = require '@lunette-plugins/desktop/manager/controller'
local boot = require './support/boot'
local expect = testing.expect
local suite = testing.suite()
local fixtures = {}

local function test(name, run)
  suite(name, function()
    fixtures = {}
    local ok, problem = pcall(run)
    local failures = if ok then {} else { tostring(problem) }
    for index = #fixtures, 1, -1 do
      local closed, failure = pcall(fixtures[index].close, fixtures[index])
      if not closed then
        failures[#failures + 1] = 'fixture cleanup: ' .. tostring(failure)
      end
    end
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end)
end

local function fixture()
  local running, fake, all, state, _, public = boot({ visible = true }, nil, { 'frame', 'surfaces', 'ui' })
  local f = { running = running, fake = fake, all = all, state = state, public = public, surface = all()[1] }
  fixtures[#fixtures + 1] = f
  function f:pointer()
    return self.public:pointer()
  end
  function f:update(pointer, x, y, fields)
    self.public:update(pointer, x, y, fields)
  end
  function f:graphPoint()
    local box = self.public:control('graph').bounds
    return box.x + 1, box.y + box.height / 2
  end
  function f:nodePoint()
    for _, item in self.public:control('graph').items do
      if item.id:sub(1, 5) == 'node/' and item.bounds then
        local box = item.bounds
        return box.x + box.width / 2, box.y + box.height / 2
      end
    end
    error('the fixture has no visible public graph node', 0)
  end
  function f:hide()
    self.public:click(self:pointer(), 'close')
  end
  function f:close()
    if not self.closed then
      self.running.runtime:close()
      self.closed = true
      self.fake.assertResourcesReleased()
    end
  end
  return f
end

local function observe(name, run)
  local original = controller[name]
  local ok, problem = pcall(run, original, function(replacement)
    controller[name] = replacement
  end)
  controller[name] = original
  if not ok then
    error(problem, 0)
  end
end

test('a real secondary press cannot activate an action or start a graph gesture', function()
  local f, pointer = fixture(), nil
  pointer = f:pointer()
  local x, y = f.public:point 'catalog'
  f:update(pointer, x, y, { buttons = { right = true } })
  expect.equal(f.state.tab, 'inspect', 'secondary press cannot activate Catalog')
  x, y = f:graphPoint()
  f:update(pointer, x, y)
  f:update(pointer, x, y, { buttons = { right = true } })
  expect.equal(f.state.view.dragging, nil, 'secondary press cannot start graph capture')
  f:update(pointer, x, y)
  f:update(pointer, x, y, { buttons = { left = true } })
  local gesture = f.state.view.dragging
  f:update(pointer, x, y, { buttons = { left = true, right = true } })
  f:update(pointer, x, y, { buttons = { left = true } })
  expect.equal(f.state.view.dragging, gesture, 'secondary release preserves primary capture')
end)

test('tracking loss cancels a click without selecting on release or held reacquisition', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = f:nodePoint()
  f:update(pointer, x, y, { buttons = { left = true } })
  expect.truthy(f.state.view.dragging, 'primary press is pending')
  pointer:withdraw()
  expect.equal(f.state.view.dragging, nil, 'tracking loss clears the gesture')
  expect.equal(f.state.view.selection, nil, 'tracking loss does not click')
  f:update(pointer, x, y, { buttons = { left = true } })
  expect.equal(f.state.view.dragging, nil, 'held reacquisition cannot press again')
  f:update(pointer, x, y)
  expect.equal(f.state.view.selection, nil, 'held release is not a click')
  f:update(pointer, x, y, { buttons = { left = true } })
  f:update(pointer, x, y)
  expect.truthy(f.state.view.selection, 'fresh input selects the node')
end)

test('a captured drag projects beyond hover bounds and releases at its projected position', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = f:graphPoint()
  local camera = f.state.view.camera
  f:update(pointer, x, y, { buttons = { left = true } })
  f:update(pointer, x - 40, y + 30, { buttons = { left = true } })
  local moved = f.state.view.camera
  expect.equal(pointer.hovered, nil, 'the ray leaves bounded hover')
  expect.truthy(f.state.view.dragging, 'leave preserves capture')
  expect.near((camera.x - moved.x) * camera.zoom, -40, 1e-3, 'projected pan x')
  expect.near((camera.y - moved.y) * camera.zoom, 30, 1e-3, 'projected pan y')
  f:update(pointer, x - 50, y + 40)
  local released = f.state.view.camera
  expect.equal(f.state.view.dragging, nil, 'release ends the gesture')
  expect.near((moved.x - released.x) * moved.zoom, -10, 1e-3, 'release retains projected x')
  expect.near((moved.y - released.y) * moved.zoom, 10, 1e-3, 'release retains projected y')
  expect.equal(f.state.view.selection, nil, 'outside drag cannot click')
end)

test('a real grip grab cancels the graph click before moving the panel pose', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = f:nodePoint()
  f:update(pointer, x, y, { buttons = { left = true } })
  local position, seen = vector.pack(f.surface.pose:getPosition()), nil
  observe('graphCancel', function(cancel, replace)
    replace(function(state)
      if state == f.state then
        seen = vector.pack(f.surface.pose:getPosition())
      end
      return cancel(state)
    end)
    f:update(pointer, x, y, { buttons = { left = true }, grip = true })
    expect.equal(pointer.grabbed, f.surface, 'grip starts a real grab')
    expect.equal(f.state.view.dragging, nil, 'the click is cancelled')
    f:update(pointer, x, y, {
      buttons = { left = true },
      grip = true,
      pose = lovr.math.newMat4():translate(0.25, 0, 0),
    })
  end)
  expect.equal(seen, position, 'cancellation precedes movement')
  expect.truthy(vector.pack(f.surface.pose:getPosition()) ~= position, 'grab moves the panel')
  expect.equal(f.state.view.selection, nil, 'grab does not activate a click')
end)

test('hide and disposal cancel real captures immediately and held input stays inert', function()
  for _, action in { 'hide', 'dispose' } do
    local f = fixture()
    local pointer = f:pointer()
    local x, y = f:graphPoint()
    f:update(pointer, x, y, { buttons = { left = true } })
    if action == 'hide' then
      f:hide()
    else
      f.running.service:disable 'desktop/manager'
    end
    expect.equal(f.state.view.dragging, nil, 'cleanup clears the domain gesture')
    local camera = f.state.view.camera
    if action == 'hide' then
      f.public:open()
      f:update(pointer, x + 30, y + 30, { buttons = { left = true } })
      expect.equal(f.state.view.dragging, nil, 'held input cannot reacquire')
      expect.equal(f.state.view.camera, camera, 'held movement cannot resume')
      f:update(pointer, x, y)
      f:update(pointer, x, y, { buttons = { left = true } })
      expect.truthy(f.state.view.dragging, 'observed release allows fresh capture')
    else
      expect.equal(f.surface.dead, true, 'disposed surface remains dead')
    end
    f:close()
  end
end)

test('shared cancellation releases exclusive ownership before a terminal observer starts another pointer', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local x, y = f:graphPoint()
  f:update(first, x, y, { buttons = { left = true } })
  local entered = false
  observe('graphCancel', function(cancel, replace)
    replace(function(state)
      cancel(state)
      if state == f.state and not entered then
        entered = true
        f:update(second, x, y, { buttons = { left = true } })
      end
    end)
    first:cancel(f.surface, 'disabled')
  end)
  expect.truthy(entered, 'terminal observer runs')
  expect.truthy(f.state.view.dragging, 'another pointer acquires detached ownership')
  f:update(second, x, y)
  expect.equal(f.state.view.dragging, nil, 'replacement pointer owns release')
end)

test('outside toolbar release and invalid graph projection never activate a click release', function()
  for _, target in { 'toolbar', 'graph' } do
    local f = fixture()
    local pointer = f:pointer()
    local x, y
    if target == 'graph' then
      x, y = f:nodePoint()
    else
      x, y = f.public:point 'catalog'
    end
    f:update(pointer, x, y, { buttons = { left = true } })
    local calls = 0
    observe('graphRelease', function(release, replace)
      replace(function(state, point)
        calls += 1
        return release(state, point)
      end)
      if target == 'graph' then
        f:update(pointer, x, y, { direction = vector.pack(1, 0, 0) })
      else
        f:update(pointer, f.state.width + 10, y)
      end
    end)
    expect.equal(calls, 0, 'invalid or outside release cannot click')
    expect.equal(f.state.view.selection, nil, 'release cannot select a node')
    expect.equal(f.state.view.dragging, nil, 'release ends the gesture')
    expect.equal(f.state.tab, 'inspect', 'outside Catalog release cannot activate')
    f:close()
  end
end)

test('an outside release cancels a pending graph click within the drag threshold', function()
  local f = fixture()
  local pointer = f:pointer()
  local box = f.public:control('graph').bounds
  local x, y = box.x + 1, box.y + box.height / 2
  f:update(pointer, x, y, { buttons = { left = true } })
  expect.equal(f.state.view.dragging.kind, 'pending-click', 'press is still pending')
  local calls = 0
  observe('graphRelease', function(release, replace)
    replace(function(state, point)
      calls += 1
      return release(state, point)
    end)
    f:update(pointer, box.x - 1, y)
  end)
  expect.equal(calls, 0, 'outside pending press cannot click')
  expect.equal(f.state.view.dragging, nil, 'pending gesture ends')
end)

test('hiding cancels secondary and rejected primary captures on every real pointer', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local x, y = f:graphPoint()
  f:update(first, x, y, { buttons = { left = true } })
  f:update(second, x, y, { buttons = { left = true, right = true } })
  f:hide()
  expect.equal(f.state.view.dragging, nil, 'hiding clears the active graph gesture')
  f.public:open()
  f:update(first, x + 20, y + 20, { buttons = { left = true } })
  expect.equal(f.state.view.dragging, nil, 'held owner capture cannot resume')
  f:update(second, x, y, { buttons = { left = true, right = true } })
  expect.equal(f.state.view.dragging, nil, 'held rejected capture cannot press')
end)

test('hide continues pointer cleanup when a graph cancellation observer raises', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local x, y = f:graphPoint()
  f:update(first, x, y, { buttons = { left = true } })
  f:update(second, x, y, { buttons = { right = true } })
  observe('graphCancel', function(cancel, replace)
    local calls = 0
    replace(function(state)
      cancel(state)
      calls += 1
      if calls == 1 then
        error('injected manager cancellation failure', 0)
      end
    end)
    f:hide()
  end)
  expect.equal(f.state.view.dragging, nil, 'gesture stays cleared')
  f.public:open()
  f:update(first, x + 20, y + 20, { buttons = { left = true } })
  f:update(second, x, y, { buttons = { right = true } })
  expect.equal(f.state.view.dragging, nil, 'held pointers remain cancelled after the failing notification')
  local reports = f.fake.events.reported
  expect.equal(#reports, 1, 'the shared UI boundary reports one callback error')
  expect.truthy(reports[1].message:find('injected manager cancellation failure', 1, true), 'the cause is retained')
end)

test('real scrolling retains the pointed graph position and the controller detail offset', function()
  local f = fixture()
  local pointer = f:pointer()
  local box = f.public:control('graph').bounds
  local x, y = box.x + 100, box.y + 100
  local camera = f.state.view.camera
  local worldX = camera.x + (x - box.x) / camera.zoom
  local worldY = camera.y + (y - box.y) / camera.zoom
  f:update(pointer, x, y, { scrollY = 1 })
  local zoomed = f.state.view.camera
  expect.truthy(zoomed.zoom > camera.zoom, 'positive scroll zooms in')
  expect.near(zoomed.x + (x - box.x) / zoomed.zoom, worldX, 1e-4, 'pointed x remains stable')
  expect.near(zoomed.y + (y - box.y) / zoomed.zoom, worldY, 1e-4, 'pointed y remains stable')
  x, y = f.public:point 'details'
  local before = f.state.scroll
  f:update(pointer, x, y, { scrollY = -1 })
  expect.truthy(f.state.scroll > before, 'negative detail scroll advances')
  f:update(pointer, x, y, { scrollY = 1 })
  expect.equal(f.state.scroll, before, 'opposite scroll restores offset')
end)

test('fractional detail scroll samples accumulate instead of being rounded away', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = f.public:point 'details'
  local before = f.state.scroll
  for _ = 1, 4 do
    f:update(pointer, x, y, { scrollY = -1, dt = 0.25 })
  end
  expect.equal(f.state.scroll, before + 1, 'four quarter-row samples advance one row')
end)

test('published graph item geometry and drawing stay stable throughout a captured pan', function()
  local f = fixture()
  local pointer = f:pointer()
  local x, y = f:graphPoint()
  local before = f.public:panel():describe()
  local items = f.public:control('graph').items
  local bounds = f.public:control('graph').bounds
  local function renderedRoutes()
    table.clear(f.fake.events.draw)
    lovr.draw(f.fake.events.pass)
    local routes = {}
    for _, call in f.fake.events.draw do
      if call[1] == 'line' and call[3] >= bounds.y and call[6] >= bounds.y then
        local parts = {}
        for index = 1, 7 do
          parts[#parts + 1] = tostring(call[index])
        end
        routes[#routes + 1] = table.concat(parts, ',')
      end
    end
    expect.truthy(#routes > 0, 'the graph renders routes inside its public clip')
    return table.concat(routes, '\n')
  end
  local rendered = renderedRoutes()
  f:update(pointer, x, y, { buttons = { left = true } })
  f:update(pointer, x + 40, y + 20, { buttons = { left = true } })
  expect.equal(f.public:panel():describe().revision, before.revision, 'captured pan defers geometry publication')
  expect.equal(f.public:control('graph').items[1].bounds.x, items[1].bounds.x, 'published route bounds remain stable')
  expect.equal(renderedRoutes(), rendered, 'drawing retains the same published graph projection during capture')
  f:update(pointer, x + 40, y + 20)
  expect.truthy(f.public:panel():describe().revision > before.revision, 'release publishes the new projection')
end)

test('a toolbar view change cancels a graph press before its retained geometry can select another target', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local x, y = f:nodePoint()
  f:update(first, x, y, { buttons = { left = true } })
  expect.truthy(
    f.state.view.dragging,
    'the first pointer owns a pending graph click; nodes=' .. tostring(#f.state.view.snapshot.nodes)
  )
  f.public:click(second, 'zoom-in')
  expect.equal(f.state.view.dragging, nil, 'changing the view cancels the original gesture')
  f:update(first, x, y)
  expect.equal(f.state.view.selection, nil, 'the old release cannot select changed geometry')
  local currentX, currentY = f:nodePoint()
  f:update(first, currentX, currentY, { buttons = { left = true } })
  f:update(first, currentX, currentY)
  expect.truthy(f.state.view.selection, 'a fresh press selects the newly published geometry')
end)

test('a captured node click never selects a replacement activation that reuses its entry id', function()
  local f = fixture()
  local pointer = f:pointer()
  local mutable = {}
  for _, entry in f.running.service:entries() do
    if not entry.protected then
      mutable[entry.instanceId] = entry.id
    end
  end
  local x, y, entryId, capturedId
  for _, item in f.public:control('graph').items do
    local box = item.bounds
    local id = item.id:sub(6)
    if item.id:sub(1, 5) == 'node/' and box and mutable[id] then
      x, y = box.x + box.width / 2, box.y + box.height / 2
      capturedId, entryId = id, mutable[id]
      break
    end
  end
  expect.truthy(entryId, 'a visible node identifies a mutable current activation')
  f:update(pointer, x, y, { buttons = { left = true } })
  f.running.service:remove(entryId)
  f.running.service:restore(entryId)
  lovr.update(0)
  local replacementId
  for _, entry in f.running.service:entries() do
    if entry.id == entryId then
      replacementId = entry.instanceId
    end
  end
  expect.truthy(replacementId ~= capturedId, 'restoration creates a different runtime instance identity')
  f:update(pointer, x, y)
  expect.equal(f.state.view.selection, nil, 'the removed captured identity is not replaced by the new activation')
end)

return suite
