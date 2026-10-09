local testing = require '@testing'
local plugin = require '@lunette-plugin'
local managerConfig = require '@lunette-plugins/desktop/manager/config'
local frameContract = require '@lunette-contracts/frame'
local boot = require './support/boot'
local expect = testing.expect
local suite = testing.suite()

local function test(name, run)
  suite(name, function()
    local fixtures = {}
    local function start(...)
      local running, fake, all, state, menu, public = boot(...)
      fixtures[#fixtures + 1] = { running = running, fake = fake }
      return running, fake, all, state, menu, public
    end
    local ok, problem = pcall(run, start)
    local failures = if ok then {} else { tostring(problem) }
    for index = #fixtures, 1, -1 do
      local f = fixtures[index]
      local closed, failure = pcall(function()
        f.running.runtime:close()
        f.fake.assertResourcesReleased()
      end)
      if not closed then
        failures[#failures + 1] = tostring(failure)
      end
    end
    if #failures > 0 then
      error(table.concat(failures, '\n'), 0)
    end
  end)
end

local function graphPoint(public)
  local bounds = public:control('graph').bounds
  return bounds.x + 1, bounds.y + bounds.height / 2
end

test('projected manager opens from the menu, moves, draws, closes, and releases on shutdown', function(start)
  local running, fake, all, _, _, public = start()
  expect.equal(#all(), 0, 'initially hidden')
  local panel = public:open()
  local offered = all()[1]
  local x, y, distance = offered:raycast(vector.pack(0, 1.4, 0), vector.pack(0, 0, -1))
  expect.truthy(x and y and distance, 'projected hit')
  expect.near(x, 640, 0.001, 'logical center x')
  panel:setPose(lovr.math.newMat4():translate(0.5, 1.4, -1.2))
  expect.equal(offered:raycast(vector.pack(-1, 1.4, 0), vector.pack(0, 0, -1)), nil, 'moved away')
  lovr.update(0.016)
  lovr.draw(fake.events.pass)
  expect.truthy(#fake.events.draw > 0, 'projected graph draws')
  public:click(public:pointer(), 'close')
  expect.equal(#all(), 0, 'Close hides the surface')
  running.runtime:close()
  expect.equal(offered:raycast(vector.pack(0.5, 1.4, 0), vector.pack(0, 0, -1)), nil, 'retained surface inert')
end)

test('management panel protects public dependencies but not inspection-only consumers', function(start)
  local running = start { visible = true }
  local protected = {}
  for _, entry in running.service:entries() do
    protected[entry.id] = entry.protected
  end
  for _, id in { 'frame', 'surfaces', 'ui', 'focus', 'menu' } do
    expect.equal(protected[id], true, id .. ' is protected')
  end
  expect.equal(protected.observer, false, 'unrelated consumer mutable')
  running.service:disable 'observer'
  expect.truthy(running.runtime:snapshot().instances[1], 'runtime remains available')
end)

test('another real pointer cannot move cancel or replace a captured graph press', function(start)
  local _, _, _, state, _, public = start { visible = true }
  local first, second = public:pointer(), public:pointer()
  local x, y = graphPoint(public)
  local camera = state.view.camera
  public:update(first, x, y, { buttons = { left = true } })
  public:update(second, x + 50, y + 50, { buttons = { left = true } })
  second:withdraw()
  expect.equal(state.view.camera, camera, 'another pointer cannot pan')
  expect.truthy(state.view.dragging, 'another pointer cannot cancel')
  public:update(first, x + 20, y + 30, { buttons = { left = true } })
  expect.near((camera.x - state.view.camera.x) * camera.zoom, 20, 1e-3, 'captured pointer moves x')
  public:update(first, x + 20, y + 30)
  expect.equal(state.view.dragging, nil, 'the captured pointer releases')
  local released = state.view.camera
  public:update(second, x, y)
  public:update(second, x, y, { buttons = { left = true } })
  public:update(second, x + 10, y + 10, { buttons = { left = true } })
  expect.near((released.x - state.view.camera.x) * released.zoom, 10, 1e-3, 'second pointer can press after release')
end)

test('Close clears capture and held input cannot resume after menu reopening', function(start)
  local _, _, _, state, _, public = start { visible = true }
  local first, closer = public:pointer(), public:pointer()
  local x, y = graphPoint(public)
  public:update(first, x, y, { buttons = { left = true } })
  public:click(closer, 'close')
  expect.equal(state.view.dragging, nil, 'hiding cancels the drag')
  public:open()
  local camera = state.view.camera
  public:update(first, x + 30, y + 30, { buttons = { left = true } })
  expect.equal(state.view.camera, camera, 'held movement cannot resume the hidden press')
  public:update(first, x, y)
  public:update(first, x, y, { buttons = { left = true } })
  expect.truthy(state.view.dragging, 'fresh input can capture again')
end)

test('shutdown invalidates retained panel methods and clears a pending gesture', function(start)
  local running, _, all, state, _, public = start { visible = true }
  local panel, offered, pointer = public:panel(), all()[1], public:pointer()
  local x, y = graphPoint(public)
  public:update(pointer, x, y, { buttons = { left = true } })
  local position = vector.pack(offered.pose:getPosition())
  running.runtime:close()
  expect.equal(panel.dead, true, 'the public panel is dead')
  expect.equal(offered.dead, true, 'the shared surface is dead')
  expect.equal(state.view.dragging, nil, 'shutdown cancels the gesture')
  panel:setPose(lovr.math.newMat4():translate(8, 9, 10))
  expect.equal(vector.pack(offered.pose:getPosition()), position, 'retained pose setter is inert')
end)

test('a real interaction pointer drops a withdrawn manager on its next update', function(start)
  local running, _, all, _, _, public = start({ visible = true }, nil, { 'frame', 'surfaces', 'ui' })
  local pointer, offered = public:pointer(), all()[1]
  expect.truthy(pointer:beginGrab(offered, lovr.math.newMat4()), 'the real pointer grabs the panel')
  running.service:disable 'desktop/manager'
  pointer:update({
    origin = vector.pack(0, 1.4, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4(),
    buttons = {},
    grip = true,
    dt = 0.016,
  }, all())
  expect.equal(pointer.grabbed, nil, 'dead surface drops while grip stays held')
end)

test('manager dimensions reject short canvases and accept minimum and maximum usable aspects', function(start)
  expect.raises(function()
    managerConfig.schema.parse({ width = 5, height = 0.1, pixels = 800 }, 'manager')
  end, nil, 'short canvas cannot fit controls')
  local minimum = managerConfig.minimumHeight
  expect.raises(function()
    managerConfig.schema.parse({ width = 5, height = (minimum - 0.1) * 5 / 800, pixels = 800 }, 'manager')
  end, nil, 'a canvas below the body-row boundary is rejected')
  for _, config in
    {
      { width = 5, height = minimum * 5 / 800, pixels = 800, visible = true },
      { width = 0.1, height = 5, pixels = 2400, visible = true },
    }
  do
    local running, _, all, state, _, public = start(managerConfig.schema.parse(config, 'manager'))
    local pointer = public:pointer()
    public:click(pointer, 'graph-view')
    public:click(pointer, 'fit')
    public:click(pointer, 'graph', 'desktop/manager')
    for _, label in { 'configure', 'catalog' } do
      public:click(pointer, label)
      local control = public:control(if label == 'configure' then 'rows' else 'catalog-list')
      expect.truthy(#control.items > 0, label .. ' has body rows')
      expect.truthy(control.items[1].bounds, label .. ' exposes a visible row')
      for _, button in public:panel():describe().controls do
        local bounds = button.bounds
        if button.kind == 'button' and bounds then
          expect.truthy(bounds.y + bounds.height <= state.height, 'all toolbar controls fit')
        end
      end
    end
    expect.equal(#all(), 3, 'valid dimensions activate the manager and titlebar')
    running.runtime:close()
  end
end)

test('a manager draw failure restores the caller transform before the next frame handler', function(start)
  local seen
  local observer = plugin.define {
    name = 'draw-observer',
    requires = { frame = frameContract.capability },
    init = function(context)
      context:require(frameContract.capability):onDraw(context, {
        phase = 'overlay',
        order = 1001,
        run = function(pass)
          seen = vector.pack(pass.current:getPosition())
        end,
      })
    end,
  }
  local _, fake = start({ visible = true }, { { id = 'draw-observer', definition = observer } })
  local pass = fake.events.pass
  pass.current = lovr.math.newMat4():translate(3, 4, 5)
  local expected, stack = vector.pack(pass.current:getPosition()), {}
  pass.push = function(self, kind)
    if kind == 'transform' then
      stack[#stack + 1] = lovr.math.newMat4(self.current)
    end
  end
  pass.pop = function(self, kind)
    if kind == 'transform' then
      self.current:set(table.remove(stack))
    end
  end
  pass.transform = function(self, pose)
    self.current:mul(pose)
  end
  pass.translate = function(self, ...)
    self.current:translate(...)
  end
  pass.scale = function(self, ...)
    self.current:scale(...)
  end
  pass.text = function()
    error('injected manager draw failure', 0)
  end
  lovr.draw(pass)
  local reports = fake.events.reported
  expect.equal(seen, expected, 'the following handler gets the original transform')
  expect.equal(#stack, 0, 'the caller transform is unwound')
  expect.equal(#reports, 1, 'the boundary reports the draw error')
  expect.truthy(reports[1].message:find('injected manager draw failure', 1, true), 'the original error is retained')
end)

test('manager uses one stable public UI panel and does not revise unchanged geometry', function(start)
  local running, _, all, _, _, public = start()
  local panel = public:open()
  local description = panel:describe()
  expect.equal(description.name, 'desktop/manager', 'the production panel name')
  expect.equal(description.visible, true, 'the menu opens the panel')
  expect.equal(public:control('graph').kind, 'region', 'graph is a public region')
  expect.equal(#all(), 3, 'the shared adapter offers the body, titlebar actions, and drag surface')
  lovr.update(0.016)
  lovr.update(0.016)
  expect.equal(panel:describe().revision, description.revision, 'unchanged frames preserve revisions')
  public:click(public:pointer(), 'close')
  expect.equal(panel:describe().visible, false, 'Close hides rather than destroys')
  expect.equal(panel.dead, false, 'the activation retains the panel')
  expect.equal(public:open(), panel, 'reopening retains panel identity')
  running.runtime:close()
  expect.equal(panel.dead, true, 'shutdown destroys the panel')
end)

return suite
