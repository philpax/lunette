-- Uses current public descriptions for each real controller gesture.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local vrUi = require '@testing/vr-ui'
local composition = require './composition'
local adapter = require '@lunette-plugin/adapter'
local management = require '@lunette-plugin/management'
local frameProvider = require '@lunette-plugins/frame'

local scenario = {}

function scenario.boot(provider)
  local services = {}
  local ledger = { activations = 0, ended = 0, actions = 0, events = {}, releases = 0, cancels = 0 }
  testing.host.useConfiguration 'examples/ui'
  local form = require 'form'
  local native = testing.native()
  local instances = {}
  local createRuntime = adapter.runtime
  adapter.runtime = function()
    local runtime = createRuntime()
    local wrapped = table.clone(runtime)
    wrapped.use = function(_self, definition, config)
      local instance = runtime:use(definition, config)
      instances[definition.name] = instance
      return instance
    end
    return wrapped
  end
  frameProvider.install { start = function() end, stop = function() end }
  local entries = desktop.compose(composition.options(provider, services, ledger, form))
  local ok, running = pcall(management.start, entries, {
    protected = { 'desktop/manager', 'desktop/menu', 'desktop/actions', 'desktop/keyboard', 'desktop/pointing' },
  })
  adapter.runtime = createRuntime
  assert(ok, running)
  for _, entry in entries do
    if entry.definition then
      instances[entry.id] = instances[entry.definition.name]
    end
  end
  local session = { instances = instances }
  function session:use(definition)
    local instance = running.runtime:use(definition, {})
    instance:enable()
    return instance
  end
  function session:close()
    running.runtime:close()
    native.assertResourcesReleased()
  end
  local env =
    { controls = vrUi.attach(native), session = session, native = native, services = services, ledger = ledger }
  scenario.resetHands(env)
  return env
end

function scenario.attach(native)
  local env = { controls = vrUi.attach(native), native = native }
  scenario.refresh(env)
  scenario.resetHands(env)
  return env
end

function scenario.refresh(env)
  local current = assert(_G.vrMigration, 'the source configuration publishes its current services')
  env.services, env.ledger = current.services, current.ledger
end

function scenario.resetHands(env)
  for _, hand in { 'left', 'right' } do
    env.controls:button(hand, 'trigger', false)
    env.controls:tracked(hand, false)
  end
  env.controls:pose('left', lovr.math.newMat4():translate(0, 1.2, -0.5))
  env.controls:tracked('left', true)
  env.controls:step()
end

function scenario.description(env, name)
  for _, panel in env.services.ui:panels() do
    local description = panel:describe()
    if description.name == name then
      return description, panel
    end
  end
  error('the current UI has no panel ' .. name)
end

function scenario.action(env, id)
  for _, action in env.services.menu:list() do
    if action.id == id then
      return action
    end
  end
  error('the current menu has no action ' .. id)
end

function scenario.open(env, id)
  scenario.resetHands(env)
  env.controls:clickControl(env.services.ui, 'desktop/menu', 'open')
  env.controls:clickControl(env.services.ui, 'desktop/menu', 'actions', 'right', id)
  env.controls:clickControl(env.services.ui, 'desktop/menu', 'close')
end

local function closeVisible(env, name)
  local current = scenario.description(env, name)
  if current.visible then
    env.controls:clickControl(env.services.ui, name, 'close')
  end
end

function scenario.search(env)
  closeVisible(env, 'example/ui/form')
  scenario.open(env, 'desktop/manager/open')
  env.controls:clickControl(env.services.ui, 'desktop/manager', 'search')
  env.controls:clickControl(env.services.ui, 'desktop/manager', 'search-field')
end

function scenario.form(env)
  closeVisible(env, 'desktop/manager')
  scenario.open(env, 'example/ui/open')
  env.controls:clickControl(env.services.ui, 'example/ui/form', 'name')
end

function scenario.keyboardCount(env)
  local count = 0
  for _, registration in env.services.keyboard:inspect().registrations do
    if registration.kind == 'keyboard' and registration.live then
      count += 1
    end
  end
  return count
end

function scenario.key(env)
  local board
  for _, surface in env.services.surfaces:all() do
    if surface.keys and surface.setVisible then
      assert(board == nil, 'only one actual shared keyboard is offered')
      board = surface
    end
  end
  assert(board and board.visible, (env.context or 'source reload') .. ': editing displays the actual shared keyboard')
  board:setPose(lovr.math.newMat4():translate(0, 0.6, -0.8))
  for _, key in board:keys() do
    if key.code == 16 then
      env.controls:click({
        pose = board.pose,
        width = board.width,
        height = board.height,
        logicalWidth = board.width,
        logicalHeight = board.height,
        visible = board.visible,
      }, key.x + key.width / 2, key.y + key.height / 2, 'left')
      return board
    end
  end
  error 'the actual shared keyboard has no q key'
end

function scenario.status(env)
  env.native.events.draw = {}
  env.controls:draw()
  for _, call in env.controls:drawCalls 'text' do
    if type(call[2]) == 'string' and call[2]:find('Presses:', 1, true) then
      return call[2]
    end
  end
  error 'the visible example form has no drawn status'
end

function scenario.capture(env, name, id)
  local description, control = env.controls:discover(env.services.ui, name, id)
  local bounds = assert(control.bounds)
  env.controls:button('right', 'trigger', false)
  env.controls:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
  env.controls:step()
  env.controls:button('right', 'trigger', true)
  env.controls:step()
end

function scenario.application(env, window)
  if not window then
    window = env.native.newWindow(82, 'migration-application')
    env.native.events.windows = { window }
    env.native.emit('onWindowOpened', { window = window })
  end
  local panel = assert(env.services.panels:forSource(window))
  panel:setPose(lovr.math.newMat4():translate(2, 1.2, -1))
  env.controls:click({
    pose = panel.pose,
    width = panel.width,
    height = panel.height,
    logicalWidth = panel.width,
    logicalHeight = panel.height,
    visible = not panel.hidden,
  }, panel.width / 2, panel.height / 2)
  if not env.services.display:isVisible() then
    scenario.open(env, 'desktop/keyboard/toggle')
  end
  env.native.events.input = {}
  scenario.key(env)
  local keys = env.controls:nativeCalls 'key'
  expect.equal(#keys, 2, 'the application receives one VR key press and release')
  expect.equal(keys[1][2], 16, 'the application receives the selected key code')
  expect.equal(keys[1][3], true, 'the application receives the key press')
  expect.equal(keys[2][3], false, 'the application receives the key release')
  return window
end

function scenario.exercise(env, window)
  scenario.search(env)
  local managerTarget = assert(env.services.focus:focused(), 'Search acquires a local focus target')
  local board = scenario.key(env)
  expect.equal(scenario.keyboardCount(env), 1, 'Search owns one actual shared keyboard')
  scenario.form(env)
  local formTarget = assert(env.services.focus:focused(), 'the form acquires a local focus target')
  expect.truthy(formTarget ~= managerTarget, 'the form replaces Search as the current route')
  local before = scenario.status(env):match 'name: (.-);'
  expect.equal(scenario.key(env), board, 'the form uses the same actual keyboard as Search')
  local edited = scenario.status(env):match 'name: (.-);'
  expect.equal(edited, before .. 'q', 'the real form consumes the VR key')
  window = scenario.application(env, window)
  expect.equal(scenario.keyboardCount(env), 1, 'the application uses the same single keyboard')
  expect.equal(scenario.status(env):match 'name: (.-);', edited, 'application typing never edits the form')
  env.controls:clickControl(env.services.ui, 'example/ui/form', 'name')
  return window
end

function scenario.live(handles)
  local count = 0
  for _, handle in handles do
    if not handle.dead then
      count += 1
    end
  end
  return count
end

function scenario.resources(env, context)
  expect.truthy(scenario.keyboardCount(env) <= 1, context .. ': at most one actual keyboard')
  expect.equal(scenario.live(env.native.events.seats), 2, context .. ': two current pointer seats')
  expect.equal(scenario.live(env.native.events.claims), 1, context .. ': one current application claim')
  for _, name in { 'onWindowOpened', 'onMonitorAdded', 'onError' } do
    expect.equal(env.native.subscriptionCount(name), 1, context .. ': one ' .. name .. ' subscription')
  end
  expect.equal(env.native.subscriptionCount 'onProcessExited', 0, context .. ': no demonstration process listener')
  local reports = testing.takeReports()
  expect.equal(#reports, 0, context .. ': no plugin reports: ' .. table.concat(reports, '; '))
  expect.equal(#env.native.events.reported, 0, context .. ': no native error reports')
end

return scenario
