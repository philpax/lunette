local testing = require '@testing'
local plugin = require '@lunette-plugin'
local managerConfig = require '@lunette-plugins/desktop/manager/config'
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

test('manager dimensions reject a short canvas and accept the minimum usable height', function(start)
  expect.raises(function()
    managerConfig.schema.parse({ width = 5, height = 0.1, pixels = 800 }, 'manager')
  end, nil, 'short canvas cannot fit controls')
  local minimum = managerConfig.minimumHeight
  local running, _, all, state, _, public = start(
    managerConfig.schema.parse({ width = 5, height = minimum * 5 / 800, pixels = 800, visible = true }, 'manager')
  )
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
end)

test('the Plugins action belongs to the manager activation and toggles its surface', function(start)
  local running, _, all, _, menu = start(nil, nil, { 'frame', 'surfaces', 'menu' })
  expect.equal(#all(), 0, 'the manager starts hidden')
  local action = menu:list()[1]
  expect.truthy(action, 'the manager registers an action')
  expect.equal(action.id, 'desktop/manager/open', 'the action id')
  expect.equal(action.label, 'Plugins', 'the action label')
  expect.equal(action.group, 'Session', 'the action group')
  expect.equal(action.order, 20, 'the action order')
  expect.equal(
    plugin.ownerLabel(menu:inspect().registrations[1].owner),
    'desktop/manager',
    'the manager owns its action'
  )
  expect.equal(menu:invoke(action.id).kind, 'invoked', 'the action opens the manager')
  local previousSurface = all()[1]
  expect.equal(menu:invoke(action.id).kind, 'invoked', 'repeated invocation toggles closed')
  expect.equal(#all(), 0, 'repeated invocation hides the surface')
  running.service:reload 'desktop/manager'
  expect.equal(previousSurface.dead, true, 'reload retires the old surface')
  expect.equal(#all(), 0, 'the replacement starts hidden')
  expect.equal(
    menu:invoke(action.id, action.registration).kind,
    'unavailable',
    'a stale menu row cannot open a replacement'
  )
  expect.equal(menu:invoke(action.id).kind, 'invoked', 'the replacement opens from the menu')
  running.service:disable 'desktop/manager'
  expect.equal(#menu:list(), 0, 'disposal removes the owner action')
  expect.equal(menu:invoke(action.id).kind, 'unavailable', 'disposed menu callbacks cannot reopen the surface')
  expect.equal(#all(), 0, 'disposal leaves no manager surface')
end)

test('real scrolling retains the pointed graph position and accumulates fractional detail scroll', function(start)
  local _, _, _, state, _, public = start { visible = true }
  local pointer = public:pointer()
  local box = public:control('graph').bounds
  local x, y = box.x + 100, box.y + 100
  local camera = state.view.camera
  local worldX = camera.x + (x - box.x) / camera.zoom
  local worldY = camera.y + (y - box.y) / camera.zoom
  public:update(pointer, x, y, { scrollY = 1 })
  local zoomed = state.view.camera
  expect.truthy(zoomed.zoom > camera.zoom, 'positive scroll zooms in')
  expect.near(zoomed.x + (x - box.x) / zoomed.zoom, worldX, 1e-4, 'pointed x remains stable')
  expect.near(zoomed.y + (y - box.y) / zoomed.zoom, worldY, 1e-4, 'pointed y remains stable')
  x, y = public:point 'details'
  local before = state.scroll
  public:update(pointer, x, y, { scrollY = -1 })
  expect.truthy(state.scroll > before, 'negative detail scroll advances')
  public:update(pointer, x, y, { scrollY = 1 })
  expect.equal(state.scroll, before, 'opposite scroll restores offset')
  before = state.scroll
  for _ = 1, 4 do
    public:update(pointer, x, y, { scrollY = -1, dt = 0.25 })
  end
  expect.equal(state.scroll, before + 1, 'four quarter-row samples advance one row')
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
