local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local controller = require '@lunette-plugins/desktop/manager/controller'
local graph = require '@lunette-plugins/desktop/manager/graph'
local schema = require '@lunette-plugin/schema'
local expect = testing.expect
local test = testing.suite()

local function click(state, label)
  controller.update(state)
  for _, button in state.buttons do
    if button.label == label then
      expect.truthy(button.enabled, label .. ' enabled')
      controller.press(state, { x = button.x + 1, y = button.y + 1 })
      return
    end
  end
  error('missing button ' .. label)
end

local function row(state, label)
  controller.update(state)
  for _, current in state.rows do
    if current.label == label or current.label == string.format('%q', label) then
      controller.press(state, { x = current.x + 1, y = current.y + 1 })
      return
    end
  end
  error('missing row ' .. label)
end

local function fixture(descriptor, config)
  local value
  descriptor = descriptor
    or schema.object {
      count = schema.default(schema.number { minimum = 0 })(1),
      enabled = schema.default(schema.boolean())(true),
      position = schema.default(schema.vector())(vector.pack(1, 2, 3)),
      callback = schema.default(schema.callback(function() end))(function() end),
    }
  local definition = plugin.consumer({
    name = 'editable',
    schema = descriptor,
    init = function(_context, settings)
      if settings.count == 9 then
        error 'initializer rejects nine'
      end
      value = settings
    end,
  }).definition
  local running = management.start { { id = 'editable', definition = definition, config = config } }
  local state = controller.new(running.service, {}, 1280, 800)
  local selected
  for _, entry in running.service:entries() do
    if entry.id == 'editable' then
      selected = entry
    end
  end
  state.view.selection = { kind = 'node', id = selected.instanceId }
  controller.update(state)
  return running, state, function()
    return value
  end
end

test('clicks edit schema fields, preserve opaque values, apply and recover failed initializers', function()
  local running, state, value = fixture()
  local callback = value().callback
  click(state, 'Configure')
  row(state, 'count')
  controller.key(state, 'backspace')
  controller.text(state, '3')
  controller.key(state, 'return')
  click(state, 'Apply')
  expect.equal(value().count, 3, 'applied draft')
  expect.equal(value().callback, callback, 'opaque callback preserved')
  row(state, 'count')
  controller.key(state, 'backspace')
  controller.text(state, '9')
  controller.key(state, 'return')
  click(state, 'Apply')
  testing.takeReports()
  expect.equal(running.service:entries()[2].state, 'failed', 'failed replacement inspectable')
  click(state, 'Recover')
  expect.equal(value().count, 3, 'previous good settings recovered')
  expect.equal(value().callback, callback, 'recovery preserves callback')
  running.runtime:close()
end)

test('invalid numeric drafts retain applied activation and show parser diagnostics', function()
  local running, state, value = fixture()
  click(state, 'Configure')
  row(state, 'count')
  controller.key(state, 'backspace')
  controller.text(state, '-1')
  controller.key(state, 'return')
  click(state, 'Apply')
  expect.equal(value().count, 1, 'failed validation does not dispose')
  expect.truthy(state.message:find('count', 1, true), 'validation visible: ' .. state.message)
  click(state, 'Disable')
  expect.equal(running.service:entries()[2].enabled, false, 'disable intent')
  click(state, 'Enable')
  expect.equal(running.service:entries()[2].state, 'active', 'reenable')
  running.runtime:close()
end)

test('graph pan zoom search and dependency controls are reachable through input', function()
  local running, state = fixture()
  local selection = state.view.selection
  click(state, 'Providers')
  click(state, 'Transitive')
  expect.equal(state.view.mode, 'providers', 'forward dependencies')
  expect.equal(state.view.transitive, true, 'closure toggle')
  click(state, 'Consumers')
  expect.equal(state.view.mode, 'consumers', 'reverse dependencies')
  controller.key(state, '/')
  controller.text(state, 'editable')
  controller.key(state, 'return')
  expect.equal(state.view.query, 'editable', 'search input')
  local camera = state.view.camera
  controller.key(state, '=')
  expect.truthy(state.view.camera.zoom > camera.zoom, 'zoom key')
  controller.press(state, { x = 1, y = 1 })
  controller.move(state, { x = 20, y = 30 })
  controller.release(state, { x = 20, y = 30 })
  expect.equal(state.view.selection.id, selection.id, 'pan does not reselect')
  local box = state.view.layout[selection.id]
  local center = graph.screen(state.view.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 })
  controller.press(state, center)
  controller.release(state, center)
  expect.equal(state.view.selection.id, selection.id, 'projected node hit')
  running.runtime:close()
end)

test('removed entries can be loaded from the projected session catalog', function()
  local running, state = fixture()
  local oldId = state.view.selection.id
  click(state, 'Remove')
  click(state, 'Catalog')
  row(state, 'editable')
  click(state, 'Load')
  local restored
  for _, entry in running.service:entries() do
    if entry.id == 'editable' then
      restored = entry
    end
  end
  expect.truthy(restored, 'loaded entry installed')
  expect.equal(restored.state, 'active', 'restored activation')
  expect.truthy(restored.instanceId ~= oldId, 'new runtime identity')
  running.runtime:close()
end)

test('cancelling map Add cannot turn a later scalar edit into a map insertion', function()
  local running, state, value = fixture(schema.object {
    count = schema.default(schema.number())(1),
    items = schema.default(schema.map(schema.number())) { existing = 2 },
  })
  click(state, 'Configure')
  row(state, 'items')
  click(state, 'Add')
  controller.text(state, 'cancelled')
  controller.key(state, 'escape')
  row(state, 'count')
  controller.key(state, 'backspace')
  controller.text(state, '4')
  controller.key(state, 'return')
  click(state, 'Apply')
  expect.equal(value().count, 4, 'the scalar edit applies')
  expect.equal(value().items.existing, 2, 'the existing map entry remains')
  expect.equal(value().items.cancelled, nil, 'the cancelled map key is not added')
  expect.equal(#testing.takeReports(), 0, 'no editor or activation failure')
  running.runtime:close()
end)

test('changing an edit target or tab cancels the pending text operation', function()
  local running, state, value = fixture(schema.object {
    count = schema.default(schema.number())(1),
    items = schema.default(schema.map(schema.number())) {},
  })
  click(state, 'Configure')
  row(state, 'items')
  click(state, 'Add')
  click(state, 'Inspect')
  expect.equal(controller.options(state).footer:find('Editing:', 1, true), nil, 'tab cancels text input')
  click(state, 'Configure')
  row(state, 'items')
  click(state, 'Add')
  row(state, 'count')
  controller.key(state, 'backspace')
  controller.text(state, '5')
  controller.key(state, 'return')
  click(state, 'Apply')
  expect.equal(value().count, 5, 'changing rows starts a scalar edit')
  expect.equal(next(value().items), nil, 'the map remains empty')
  row(state, 'count')
  controller.key(state, 'tab')
  expect.equal(state.tab, 'inspect', 'the tab key changes tabs during an edit')
  expect.equal(state.edit, nil, 'the tab key cancels pending text')
  click(state, 'Configure')
  row(state, 'count')
  state.view.selection = nil
  controller.update(state)
  expect.equal(state.edit, nil, 'a removed selection cancels the edit')
  expect.equal(state.text, '', 'a removed selection clears pending text')
  running.runtime:close()
end)

test('editor button outcomes remain visible instead of becoming generic action success', function()
  local running, state = fixture()
  click(state, 'Configure')
  row(state, 'enabled')
  expect.truthy(state.message:find('Draft changed', 1, true), 'toggle status')
  click(state, 'Reset')
  expect.truthy(state.message:find('Draft changed', 1, true), 'reset retains the editor status')
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no generic success replaces the editor status')
  running.runtime:close()
end)

test('a collection with nonliteral union children cannot seed or report a successful Add', function()
  local running, state, value = fixture(schema.object {
    items = schema.default(schema.array(schema.union(schema.number(), schema.string()))) {},
  })
  click(state, 'Configure')
  row(state, 'items')
  local before = state.message
  local add
  for _, button in state.buttons do
    if button.label == 'Add' then
      add = button
    end
  end
  expect.equal(add.enabled, false, 'an unseedable child disables Add')
  controller.press(state, { x = add.x + 1, y = add.y + 1 })
  expect.equal(state.message, before, 'a rejected Add cannot report success')
  click(state, 'Apply')
  expect.equal(#value().items, 0, 'the collection remains empty')
  running.runtime:close()
end)

test('the public controller rejects unusable or nonfinite canvas dimensions', function()
  local running = fixture()
  for _, dimensions in
    {
      { 1280, 16 },
      { 0, 800 },
      { 799, 800 },
      { -1, 800 },
      { math.huge, 800 },
      { 1280, math.huge },
      { 0 / 0, 800 },
      { 1280, 0 / 0 },
    }
  do
    expect.raises(function()
      controller.new(running.service, {}, dimensions[1], dimensions[2])
    end, nil, 'invalid canvas dimensions')
  end
  for _, dimensions in { { 800, 426 }, { 2400, 120000 } } do
    local state = controller.new(running.service, {}, dimensions[1], dimensions[2])
    expect.equal(state.height, dimensions[2], 'usable dimensions are accepted')
  end
  running.runtime:close()
end)

test('duplicate map keys keep their rejection diagnostic and leave the draft unchanged', function()
  local running, state, value = fixture(schema.object {
    items = schema.default(schema.map(schema.number())) { existing = 2 },
  })
  click(state, 'Configure')
  row(state, 'items')
  click(state, 'Add')
  controller.text(state, 'existing')
  controller.key(state, 'return')
  expect.truthy(state.message:find('key already exists', 1, true), 'the rejection remains visible')
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no generic success')
  click(state, 'Apply')
  expect.equal(value().items.existing, 2, 'the rejected add does not replace the entry')
  running.runtime:close()
end)

test('optional bound defaults and false values can be unset and set independently of value edits', function()
  local running, state, value = fixture(
    schema.object {
      count = schema.optional(schema.default(schema.number())(7)),
      enabled = schema.optional(schema.default(schema.boolean())(false)),
      label = schema.optional(schema.default(schema.string()) 'initial'),
      group = schema.optional(schema.object { nested = schema.default(schema.number())(2) }),
      callback = schema.optional(schema.default(schema.callback(function() end))(function() end)),
    },
    { count = 7, enabled = false, label = 'initial', group = { nested = 2 }, callback = function() end }
  )
  local callback = value().callback
  click(state, 'Configure')
  for _, label in { 'count', 'enabled', 'label', 'group' } do
    row(state, label)
    click(state, 'Unset')
  end
  click(state, 'Apply')
  expect.equal(value().count, nil, 'an optional bound number becomes absent')
  expect.equal(value().enabled, nil, 'false becomes absent rather than true')
  expect.equal(value().label, nil, 'an optional string becomes absent')
  expect.equal(value().group, nil, 'an optional group becomes absent')
  expect.equal(value().callback, callback, 'opaque callback survives other optional edits')
  for _, label in { 'count', 'enabled', 'label', 'group' } do
    row(state, label)
    click(state, 'Set')
  end
  click(state, 'Apply')
  expect.equal(value().count, 0, 'set creates an editable number again')
  expect.equal(value().enabled, false, 'set creates an editable false value again')
  expect.equal(value().label, '', 'set creates an editable string again')
  expect.truthy(value().group, 'set creates an editable group again')
  row(state, 'callback')
  for _, button in state.buttons do
    if button.label == 'Unset' then
      expect.equal(button.enabled, false, 'opaque optional cannot be unset')
    end
  end
  running.runtime:close()
end)

test('an unseedable optional Set keeps its editor rejection rather than reporting action success', function()
  local running, state, value = fixture(schema.object {
    item = schema.optional(schema.union(schema.number(), schema.string())),
  })
  click(state, 'Configure')
  row(state, 'item')
  click(state, 'Set')
  expect.truthy(
    state.message:find('cannot create an editable value', 1, true),
    'the seed rejection is visible: ' .. state.message
  )
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no success message overwrites the rejection')
  click(state, 'Apply')
  expect.equal(value().item, nil, 'the rejected Set leaves the optional absent')
  running.runtime:close()
end)

return test
