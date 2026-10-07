local testing = require '@testing'
local plugin = require '@lunette-plugin'
local interactionContract = require '@lunette-contracts/interaction'
local interaction = require '@lunette-plugins/interaction'
local drops = require '@lunette-plugins/drops'
local focus = require '@lunette-plugins/focus'
local schema = require '@lunette-plugin/schema'
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
        failures[#failures + 1] = tostring(failure)
      end
    end
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end)
end

local function fixture(config)
  config = config or { width = 5, height = 2.6625, pixels = 800 }
  local service, owner
  local observer = plugin.define {
    name = 'navigation-pointer-observer',
    requires = { interaction = interactionContract.capability },
    init = function(context)
      service, owner = context:require(interactionContract.capability), context
    end,
  }
  local editable = plugin.consumer({
    name = 'editable',
    schema = schema.object { enabled = schema.default(schema.boolean())(true) },
    init = function() end,
  }).definition
  local running, fake, all, state, menu = boot(config, {
    { id = 'drops', definition = drops.definition },
    { id = 'focus', definition = focus.definition },
    { id = 'interaction', definition = interaction.definition },
    { id = 'navigation-pointer-observer', definition = observer },
    { id = 'editable', definition = editable },
  }, { 'frame', 'surfaces', 'menu' })
  local f = {
    running = running,
    fake = fake,
    all = all,
    state = state,
    menu = menu,
    width = config.pixels,
    height = config.pixels * config.height / config.width,
  }
  fixtures[#fixtures + 1] = f
  function f:close()
    if not self.closed then
      self.running.runtime:close()
      self.closed = true
      self.fake.assertResourcesReleased()
    end
  end
  function f:open()
    local result = self.menu:invoke 'desktop/manager/open'
    expect.equal(result.kind, 'invoked', 'the public menu action opens the manager')
    self.surface = self.all()[1]
    expect.truthy(self.surface, 'the menu exposes the manager surface')
  end
  function f:pointer()
    return service:newPointer(owner)
  end
  function f:update(pointer, x, y, buttons)
    local offered = self.surface
    pointer:update({
      origin = vector.pack(
        offered.pose:mul((x / self.width - 0.5) * offered.width, (0.5 - y / self.height) * offered.height, 1, 1)
      ),
      direction = vector.pack(offered.pose:mul(0, 0, -1, 0)),
      pose = lovr.math.newMat4(),
      buttons = buttons or {},
      grip = false,
      dt = 1,
    }, self.all())
  end
  function f:point(label)
    table.clear(self.fake.events.draw)
    lovr.draw(self.fake.events.pass)
    for _, call in self.fake.events.draw do
      if call[1] == 'text' and call[2] == label then
        return call[3] + 2, call[4] + 2
      end
    end
    error('the manager does not render ' .. label, 0)
  end
  function f:select(pointer, name)
    for _, node in self.state.view.snapshot.nodes do
      if node.name == name then
        local box = self.state.view.layout[node.id]
        local camera = self.state.view.camera
        local x = (box.x + box.width / 2 - camera.x) * camera.zoom
        local y = (box.y + box.height / 2 - camera.y) * camera.zoom
        self:update(pointer, x, y, { left = true })
        self:update(pointer, x, y)
        return
      end
    end
    error('the fixture graph has no ' .. name, 0)
  end
  function f:click(pointer, label)
    local x, y = self:point(label)
    self:update(pointer, x, y, { left = true })
    self:update(pointer, x, y)
  end
  return f
end

test('the Plugins action belongs to the manager activation and only opens its surface', function()
  local f = fixture()
  expect.equal(#f.all(), 0, 'the manager starts hidden')
  local action = f.menu:list()[1]
  expect.truthy(action, 'the manager registers an action')
  expect.equal(action.id, 'desktop/manager/open', 'the action id')
  expect.equal(action.label, 'Plugins', 'the action label')
  expect.equal(action.group, 'Session', 'the action group')
  expect.equal(action.order, 20, 'the action order')
  expect.equal(
    plugin.ownerLabel(f.menu:inspect().registrations[1].owner),
    'desktop/manager',
    'the manager owns its action'
  )
  f:open()
  f:open()
  expect.equal(#f.all(), 1, 'repeated invocation does not toggle closed')
  local previousSurface = f.surface
  f.running.service:reload 'desktop/manager'
  expect.equal(previousSurface.dead, true, 'reload retires the old surface')
  expect.equal(#f.all(), 0, 'the replacement starts hidden')
  expect.equal(
    f.menu:invoke(action.id, action.registration).kind,
    'unavailable',
    'a stale menu row cannot open a replacement'
  )
  f:open()
  f.running.service:disable 'desktop/manager'
  expect.equal(#f.menu:list(), 0, 'disposal removes the owner action')
  expect.equal(f.menu:invoke(action.id).kind, 'unavailable', 'disposed menu callbacks cannot reopen the surface')
  expect.equal(#f.all(), 0, 'disposal leaves no manager surface')
end)

test('real pointer toolbar clicks zoom focus fit enter search and close without keyboard navigation', function()
  local f = fixture()
  f:open()
  local pointer = f:pointer()
  local initial = f.state.view.camera
  local x, y = f:point 'Zoom in'
  f:update(pointer, x, y, { left = true })
  expect.equal(f.state.view.camera, initial, 'press alone cannot zoom')
  f:update(pointer, x, y)
  expect.truthy(f.state.view.camera.zoom > initial.zoom, 'release zooms in')
  f:click(pointer, 'Zoom out')
  expect.near(f.state.view.camera.zoom, initial.zoom, 1e-6, 'zoom out reverses the step')
  f:select(pointer, 'editable')
  expect.truthy(f.state.view.selection, 'a graph node is selected through the surface')
  local selected = f.state.view.selection.id
  f:update(pointer, 1, f.height / 2, { left = true })
  f:update(pointer, 41, f.height / 2 + 20, { left = true })
  f:update(pointer, 41, f.height / 2 + 20)
  f:click(pointer, 'Focus')
  local box = f.state.view.layout[selected]
  local camera = f.state.view.camera
  expect.near((box.x + box.width / 2 - camera.x) * camera.zoom, f.state.view.viewport.x / 2, 1e-4, 'focus centers x')
  expect.near((box.y + box.height / 2 - camera.y) * camera.zoom, f.state.view.viewport.y / 2, 1e-4, 'focus centers y')
  f:click(pointer, 'Search')
  expect.equal(f.state.view.searchActive, true, 'Search enters the domain search state')
  f:click(pointer, 'Fit')
  expect.equal(f.state.view.searchActive, false, 'Fit exits search')
  local fitted = f.state.view.camera
  f:click(pointer, 'Fit')
  expect.near(f.state.view.camera.x, fitted.x, 1e-6, 'Fit is idempotent at the current graph x')
  expect.near(f.state.view.camera.y, fitted.y, 1e-6, 'Fit is idempotent at the current graph y')
  expect.near(f.state.view.camera.zoom, fitted.zoom, 1e-6, 'Fit is idempotent at the current graph zoom')
  f:click(pointer, 'Close')
  expect.equal(#f.all(), 0, 'Close hides the manager')
  expect.equal(f.surface.dead, false, 'Close does not dispose the activation')
  f:open()
  expect.equal(#f.all(), 1, 'the menu can reopen a closed manager')
end)

test('new pointer controls require matching eligible release and reject tracking loss', function()
  local f = fixture()
  f:open()
  local pointer = f:pointer()
  for _, label in { 'Zoom in', 'Zoom out', 'Focus', 'Search', 'Close' } do
    local before = f.state.view.camera
    local x, y = f:point(label)
    f:update(pointer, x, y, { left = true })
    f:update(pointer, f.width + 10, y)
    expect.equal(f.state.view.camera, before, label .. ' cannot activate outside')
    expect.equal(f.state.view.searchActive, false, label .. ' cannot enter search outside')
    expect.equal(#f.all(), 1, label .. ' cannot close outside')
    f:update(pointer, x, y, { left = true })
    pointer:withdraw()
    f:update(pointer, x, y, { left = true })
    f:update(pointer, x, y)
    expect.equal(f.state.view.camera, before, label .. ' cannot activate after tracking loss')
    expect.equal(f.state.view.searchActive, false, label .. ' cannot enter search after tracking loss')
    expect.equal(#f.all(), 1, label .. ' cannot close after tracking loss')
  end
  local x, y = f:point 'Search'
  f:update(pointer, x, y, { left = true })
  local otherX, otherY = f:point 'Zoom in'
  f:update(pointer, otherX, otherY)
  expect.equal(f.state.view.searchActive, false, 'release on another control cannot activate either control')
end)

test('Close cancels other real pointer captures and held input cannot resume after menu reopen', function()
  local f = fixture()
  f:open()
  local first, second = f:pointer(), f:pointer()
  local cancelled = {}
  local handler = f.surface.onPointer
  f.surface.onPointer = function(self, event)
    if event.kind == 'cancel' then
      cancelled[#cancelled + 1] = event
    end
    return handler(self, event)
  end
  local x, y = f:point 'Close'
  f:update(first, x, y, { left = true })
  f:update(second, 1, f.height / 2, { left = true, right = true })
  f:update(first, x, y)
  expect.equal(#f.all(), 0, 'Close withdraws the surface')
  expect.equal(#cancelled, 2, 'both buttons on another pointer cancel immediately')
  for _, event in cancelled do
    expect.equal(event.pointer, second, 'the remaining captured pointer is cancelled')
    expect.equal(event.reason, 'hidden', 'Close uses hidden cancellation')
  end
  expect.equal(f.state.view.dragging, nil, 'Close clears the graph gesture')
  f:open()
  f:update(second, 1, f.height / 2 + 20, { left = true, right = true })
  expect.equal(f.state.view.dragging, nil, 'held input cannot resume after reopen')
  f:update(second, 1, f.height / 2)
  f:update(second, 1, f.height / 2, { left = true })
  expect.truthy(f.state.view.dragging, 'a fresh primary press starts a gesture')
end)

test('the accepted minimum canvas exposes every action and one configure or catalog row', function()
  local f = fixture()
  f:open()
  local pointer = f:pointer()
  expect.equal(f.height, 426, 'the accepted logical minimum is unchanged')
  f:select(pointer, 'editable')
  for _, button in f.state.buttons do
    expect.truthy(button.x >= 0 and button.x + button.width <= f.width, button.label .. ' fits horizontally')
    expect.truthy(button.y >= 0 and button.y + button.height <= f.height, button.label .. ' fits vertically')
    f:point(button.label)
  end
  for _, label in { 'Configure', 'Catalog' } do
    f:click(pointer, label)
    expect.truthy(#f.state.rows > 0, label .. ' exposes a body row')
    local row = f.state.rows[1]
    expect.truthy(row.y + row.height <= f.height - 64, label .. ' row fits above the footer')
  end
end)

return suite
