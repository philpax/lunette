local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local controller = require '../private/composition/controller'
local graph = require '../private/inspection/graph'
local schema = require '@lunette-plugin/schema'
local expect = testing.expect
local test = testing.suite()

type Settings = { count: number, callback: () -> () }

local function invoke(state: controller.State, id: string): ()
  controller.update(state)
  local action = assert(controller.button(state, id), 'missing action ' .. id)
  expect.equal(action.reason, nil, id .. ' enabled')
  controller.invoke(state, id)
end

local function row(state: controller.State, label: string): ()
  controller.update(state)
  for index, current in state.editorRows do
    if current.label == label or current.label == string.format('%q', label) then
      controller.selectRow(state, index)
      return
    end
  end
  error('missing row ' .. label)
end

local function entry(running: management.Running): management.Entry?
  for _, current in running.service:entries() do
    if current.id == 'editable' then
      return current
    end
  end
  return nil
end

local function fixture(options: management.Options?): (management.Running, controller.State, () -> Settings?)
  local value: Settings?
  local definition = plugin.consumer({
    name = 'editable',
    schema = schema.object {
      count = schema.default(schema.number { minimum = 0 })(1),
      callback = schema.default(schema.callback(function() end))(function() end),
    },
    init = function(_context: plugin.Context, settings: Settings)
      if settings.count == 9 then
        error 'initializer rejects nine'
      end
      value = settings
    end,
  }).definition
  local running = management.start({ { id = 'editable', definition = definition } }, options)
  local state = controller.new(running.service, {})
  invoke(state, 'graph-view')
  controller.resize(state, 640, 480)
  state.view.selection = { kind = 'node', id = assert(entry(running)).instanceId }
  controller.update(state)
  return running, state, function(): Settings?
    return value
  end
end

local function confirm(state: controller.State, text: string): boolean
  controller.setText(state, text)
  return controller.confirmText(state)
end

test('configuration edits apply on Apply and Recover restores the last good settings', function()
  local running, state, value = fixture()
  local callback = value().callback
  invoke(state, 'configure')
  row(state, 'count')
  expect.falsy(confirm(state, 'not a number'), 'invalid text is rejected')
  expect.truthy(state.edit, 'the rejected edit stays open')
  expect.truthy(state.message:find('finite number', 1, true), 'the parser diagnostic is visible')
  expect.truthy(confirm(state, '3'))
  expect.equal(value().count, 1, 'confirmation is not Apply')
  invoke(state, 'apply')
  expect.equal(value().count, 3)
  expect.equal(value().callback, callback, 'opaque values keep their identity')
  row(state, 'count')
  confirm(state, '-1')
  invoke(state, 'apply')
  expect.equal(value().count, 3, 'a refinement failure keeps the activation')
  expect.truthy(state.message:find('count', 1, true), 'the validation failure is visible')
  row(state, 'count')
  confirm(state, '9')
  invoke(state, 'apply')
  testing.takeReports()
  expect.equal(assert(entry(running)).state, 'failed')
  invoke(state, 'recover')
  expect.equal(value().count, 3, 'the previous good settings return')
  expect.equal(value().callback, callback)
  running.runtime:close()
end)

test('lifecycle actions change the entry and the catalog loads a removed entry', function()
  local running, state = fixture()
  local oldId = state.view.selection.id
  invoke(state, 'disable')
  expect.equal(assert(entry(running)).enabled, false)
  invoke(state, 'enable')
  expect.equal(assert(entry(running)).state, 'active')
  invoke(state, 'remove')
  expect.equal(entry(running), nil)
  invoke(state, 'catalog')
  controller.selectCatalog(state, 'editable')
  invoke(state, 'load')
  local restored = assert(entry(running))
  expect.equal(restored.state, 'active')
  expect.truthy(restored.instanceId ~= oldId, 'the loaded entry is a new instance')
  running.runtime:close()
end)

test('protected entries cannot be disabled, reloaded, or removed', function()
  local running, state = fixture { protected = { 'editable' } }
  controller.update(state)
  for _, id in { 'disable', 'reload', 'remove' } do
    local action = assert(controller.button(state, id), 'missing action ' .. id)
    expect.equal(action.reason, 'The entry is protected.', id .. ' is disabled')
    expect.falsy(controller.invoke(state, id), id .. ' cannot run')
  end
  expect.falsy(controller.invoke(state, 'remove'))
  expect.truthy(entry(running), 'the entry remains')
  running.runtime:close()
end)

test('graph input in canvas pixels selects on click and pans on drag', function()
  local running, state = fixture()
  local selected = state.view.selection.id
  controller.select(state, nil)
  local box = state.view.layout[selected]
  local point = graph.screen(state.view.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
  controller.graphPress(state, point)
  controller.graphRelease(state, point, true)
  expect.equal(state.view.selection.id, selected, 'a click selects the node under the pointer')
  local camera = state.view.camera
  controller.graphPress(state, point)
  controller.graphMove(state, { x = point.x + 30, y = point.y + 30 })
  controller.graphRelease(state, { x = point.x + 30, y = point.y + 30 }, true)
  expect.truthy(state.view.camera.x ~= camera.x, 'a drag pans')
  controller.select(state, nil)
  controller.graphPress(state, point)
  controller.graphRelease(state, point, false)
  expect.equal(state.view.selection, nil, 'a release outside the canvas selects nothing')
  running.runtime:close()
end)

test('actions that unload plugins ask for confirmation and name what they unload', function()
  local running, state = fixture()
  expect.equal(controller.confirmation(state, 'enable'), nil, 'Enable runs directly')
  local confirmation = assert(controller.confirmation(state, 'remove'))
  expect.equal(confirmation.entry, 'editable')
  expect.equal(confirmation.title, 'Remove editable?')
  expect.truthy(confirmation.body:find('Catalog', 1, true), 'the body says how to undo it')
  running.runtime:close()
end)

test('text actions are available only during an edit and leave no stale binding', function()
  local running, state = fixture()
  expect.equal(controller.button(state, 'confirm'), nil, 'Confirm is absent outside an edit')
  expect.falsy(controller.invoke(state, 'missing'), 'an unknown action cannot run')
  invoke(state, 'configure')
  row(state, 'count')
  for _, id in { 'confirm', 'cancel', 'clear' } do
    local action = assert(controller.button(state, id), id .. ' is available during an edit')
    expect.equal(action.reason, nil, id .. ' is enabled')
  end
  controller.setText(state, '3')
  expect.truthy(controller.invoke(state, 'confirm'), 'the named Confirm action edits the draft')
  expect.equal(state.edit, nil, 'Confirm ends the edit')
  expect.equal(controller.button(state, 'confirm'), nil, 'refresh removes the conditional record')
  expect.falsy(controller.invoke(state, 'confirm'), 'the old action id has no stale binding')
  running.runtime:close()
end)

test('disabled actions carry the reason they are disabled', function()
  local running, state = fixture { protected = { 'editable' } }
  controller.update(state)
  expect.equal(assert(controller.button(state, 'remove')).reason, 'The entry is protected.')
  expect.equal(assert(controller.button(state, 'enable')).reason, 'The entry is enabled.')
  expect.equal(controller.confirmation(state, 'remove'), nil, 'a disabled action asks nothing')
  controller.select(state, nil)
  expect.equal(assert(controller.button(state, 'reload')).reason, 'Select a plugin entry first.')
  running.runtime:close()
end)

return test
