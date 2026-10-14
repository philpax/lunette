local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local controller = require '../private/composition/controller'
local graph = require '../private/inspection/graph'
local schema = require '@lunette-plugin/schema'
local expect = testing.expect
local test = testing.suite()

type Settings = { count: number, callback: () -> () }

local function invoke(state: controller.State, id: string)
  controller.update(state)
  for _, button in state.buttons do
    if button.id == id then
      expect.truthy(button.enabled, id .. ' enabled')
      controller.invoke(state, id)
      return
    end
  end
  error('missing action ' .. id)
end

local function row(state: controller.State, label: string)
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
  local state = controller.new(running.service, {}, 1280, 800)
  invoke(state, 'graph-view')
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
  for _, button in state.buttons do
    if button.id == 'disable' or button.id == 'reload' or button.id == 'remove' then
      expect.falsy(button.enabled, button.id .. ' is disabled')
    end
  end
  expect.falsy(controller.invoke(state, 'remove'))
  expect.truthy(entry(running), 'the entry remains')
  running.runtime:close()
end)

test('graph input in panel coordinates selects on click and pans on drag', function()
  local running, state = fixture()
  local selected = state.view.selection.id
  state.view.selection = nil
  local bounds = state.layout.graphBounds
  local box = state.view.layout[selected]
  local center = graph.screen(state.view.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
  local point = { x = center.x + bounds.x, y = center.y + bounds.y }
  controller.graphPress(state, point)
  controller.graphRelease(state, point)
  expect.equal(state.view.selection.id, selected, 'a click selects the node under the pointer')
  local camera = state.view.camera
  controller.graphPress(state, point)
  controller.graphMove(state, { x = point.x + 30, y = point.y + 30 })
  controller.graphRelease(state, { x = point.x + 30, y = point.y + 30 })
  expect.truthy(state.view.camera.x ~= camera.x, 'a drag pans')
  controller.graphPress(state, { x = bounds.x + 1, y = bounds.y - 1 })
  expect.equal(state.view.dragging, nil, 'toolbar input is not a graph gesture')
  running.runtime:close()
end)

return test
