local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local controller = require '@lunette-plugins/desktop/manager/controller'
local graph = require '@lunette-plugins/desktop/manager/graph'
local schema = require '@lunette-plugin/schema'
local expect = testing.expect
local test = testing.suite()

local function invoke(state, id)
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

local function row(state, label)
  controller.update(state)
  if state.tab == 'catalog' then
    controller.selectCatalog(state, label)
    return
  end
  for index, current in state.editorRows do
    if current.label == label or current.label == string.format('%q', label) then
      controller.selectRow(state, index)
      return index
    end
  end
  error('missing row ' .. label)
end

local function fixture(descriptor, config, options)
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
  local running = management.start({ { id = 'editable', definition = definition, config = config } }, options)
  local state = controller.new(running.service, {}, 1280, 800)
  invoke(state, 'graph-view')
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

local function confirm(state, text)
  controller.setText(state, text)
  return controller.confirmText(state)
end

local function panelPoint(state, point)
  return { x = point.x + state.layout.graphBounds.x, y = point.y + state.layout.graphBounds.y }
end

test('domain actions edit schema fields, preserve opaque values, apply and recover failed initializers', function()
  local running, state, value = fixture()
  local callback = value().callback
  invoke(state, 'configure')
  row(state, 'count')
  confirm(state, '3')
  invoke(state, 'apply')
  expect.equal(value().count, 3, 'applied draft')
  expect.equal(value().callback, callback, 'opaque callback preserved')
  row(state, 'count')
  confirm(state, '9')
  invoke(state, 'apply')
  testing.takeReports()
  expect.equal(running.service:entries()[2].state, 'failed', 'failed replacement inspectable')
  invoke(state, 'recover')
  expect.equal(value().count, 3, 'previous good settings recovered')
  expect.equal(value().callback, callback, 'recovery preserves callback')
  running.runtime:close()
end)

test('graph pan zoom search and dependency controls are reachable through domain methods', function()
  local running, state = fixture()
  local selection = state.view.selection
  invoke(state, 'providers')
  invoke(state, 'transitive')
  expect.equal(state.view.mode, 'providers', 'forward dependencies')
  expect.equal(state.view.transitive, true, 'closure toggle')
  invoke(state, 'consumers')
  expect.equal(state.view.mode, 'consumers', 'reverse dependencies')
  invoke(state, 'search')
  controller.setSearch(state, 'editable')
  controller.endSearch(state)
  expect.equal(state.view.query, 'editable', 'search input')
  local camera = state.view.camera
  invoke(state, 'zoom-in')
  expect.truthy(state.view.camera.zoom > camera.zoom, 'zoom action')
  controller.graphPress(state, panelPoint(state, { x = 1, y = 1 }))
  controller.graphMove(state, panelPoint(state, { x = 20, y = 30 }))
  controller.graphRelease(state, panelPoint(state, { x = 20, y = 30 }))
  expect.equal(state.view.selection.id, selection.id, 'pan does not reselect')
  local box = state.view.layout[selection.id]
  local center =
    panelPoint(state, graph.screen(state.view.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 }))
  controller.graphPress(state, center)
  controller.graphRelease(state, center)
  expect.equal(state.view.selection.id, selection.id, 'projected node hit')
  running.runtime:close()

  running, state = fixture()
  selection = state.view.selection
  local bounds = state.layout.graphBounds
  expect.truthy(bounds.y > 0, 'the graph begins below its controls')
  controller.graphPress(state, { x = bounds.x + 1, y = bounds.y - 1 })
  expect.equal(state.view.dragging, nil, 'toolbar input is not a graph gesture')
  local box = state.view.layout[selection.id]
  local point =
    panelPoint(state, graph.screen(state.view.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 }))
  controller.graphPress(state, point)
  controller.graphRelease(state, point)
  expect.equal(state.view.selection.id, selection.id, 'the translated node is selected')
  running.runtime:close()

  running, state = fixture()
  local zoomPoint = { x = 123, y = 210 }
  local before = graph.world(state.view.camera, zoomPoint)
  controller.graphZoom(state, panelPoint(state, zoomPoint), 1.2)
  local after = graph.world(state.view.camera, zoomPoint)
  expect.near(after.x, before.x, 1e-8, 'the cursor graph x remains fixed')
  expect.near(after.y, before.y, 1e-8, 'the cursor graph y remains fixed')
  running.runtime:close()
end)

test('changing an edit target or tab cancels the pending text operation', function()
  local running, state, value = fixture(schema.object {
    count = schema.default(schema.number())(1),
    items = schema.default(schema.map(schema.number())) {},
  })
  invoke(state, 'configure')
  row(state, 'items')
  invoke(state, 'add')
  controller.setText(state, 'cancelled')
  controller.cancelText(state)
  invoke(state, 'inspect')
  expect.equal(controller.options(state).footer:find('Editing:', 1, true), nil, 'tab cancels text input')
  invoke(state, 'configure')
  row(state, 'items')
  invoke(state, 'add')
  row(state, 'count')
  confirm(state, '5')
  invoke(state, 'apply')
  expect.equal(value().count, 5, 'changing rows starts a scalar edit')
  expect.equal(next(value().items), nil, 'the map remains empty')
  row(state, 'count')
  invoke(state, 'inspect')
  expect.equal(state.tab, 'inspect', 'the domain action changes tabs during an edit')
  expect.equal(state.edit, nil, 'the tab action cancels pending text')
  invoke(state, 'configure')
  row(state, 'count')
  state.view.selection = nil
  controller.update(state)
  expect.equal(state.edit, nil, 'a removed selection cancels the edit')
  expect.equal(state.text, '', 'a removed selection clears pending text')
  expect.equal(#testing.takeReports(), 0, 'no editor or activation failure')
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
  invoke(state, 'configure')
  for _, label in { 'count', 'enabled', 'label', 'group' } do
    row(state, label)
    invoke(state, 'optional')
  end
  invoke(state, 'apply')
  expect.equal(value().count, nil, 'an optional bound number becomes absent')
  expect.equal(value().enabled, nil, 'false becomes absent rather than true')
  expect.equal(value().label, nil, 'an optional string becomes absent')
  expect.equal(value().group, nil, 'an optional group becomes absent')
  expect.equal(value().callback, callback, 'opaque callback survives other optional edits')
  for _, label in { 'count', 'enabled', 'label', 'group' } do
    row(state, label)
    invoke(state, 'optional')
  end
  invoke(state, 'apply')
  expect.equal(value().count, 0, 'set creates an editable number again')
  expect.equal(value().enabled, false, 'set creates an editable false value again')
  expect.equal(value().label, '', 'set creates an editable string again')
  expect.truthy(value().group, 'set creates an editable group again')
  row(state, 'callback')
  for _, button in state.buttons do
    if button.id == 'optional' then
      expect.equal(button.enabled, false, 'opaque optional cannot be unset')
    end
  end
  running.runtime:close()
end)

test('unsupported string edits decode losslessly while rejected escapes retain the operation and diagnostic', function()
  local original = 'first\n\t' .. utf8.char(0x85, 0x2028, 0x2029) .. string.char(255)
  local callback = function() end
  local running, state, value = fixture(schema.object {
    title = schema.default(schema.string())(original),
    sibling = schema.default(schema.string()) '\\n literal',
    callback = schema.default(schema.callback(callback))(callback),
  })
  invoke(state, 'configure')
  local model = state.draft
  row(state, 'title')
  local encoded = 'first\\n\\t\\xC2\\x85\\xE2\\x80\\xA8\\xE2\\x80\\xA9\\xFF'
  expect.equal(state.text, encoded, 'activation uses a safe single-line representation')
  expect.equal(state.draft, model, 'selecting a string does not commit a draft')
  expect.equal(value().title, original, 'selecting does not replace the activation')
  expect.truthy(state.message:find('escaped', 1, true), 'the field explains its representation')
  local edit = state.edit
  controller.setText(state, '\n')
  expect.equal(state.text, encoded, 'unsafe direct text updates retain the representable field')
  expect.equal(state.draft, model, 'unsafe direct text updates retain the draft')
  expect.equal(state.edit, edit, 'unsafe direct text updates retain the operation')
  expect.truthy(#state.message > 0, 'the text-domain rejection is visible')
  expect.falsy(confirm(state, '\\q'), 'a malformed escape rejects confirmation')
  expect.equal(state.draft, model, 'rejection preserves the model')
  expect.equal(state.edit, edit, 'rejection preserves the edit target')
  expect.equal(state.text, '\\q', 'rejected text stays editable')
  expect.truthy(state.message:find('escape', 1, true), 'the decoder diagnostic remains visible')
  controller.update(state)
  expect.truthy(state.message:find('escape', 1, true), 'updates retain the rejection')
  expect.truthy(confirm(state, encoded), 'the unchanged representation decodes')
  expect.equal(state.draft, model, 'unchanged confirmation preserves the model')
  row(state, 'title')
  expect.truthy(confirm(state, encoded .. '\\x00\\n'), 'supported escapes commit the decoded draft')
  expect.equal(value().title, original, 'confirmation is not Apply')
  invoke(state, 'apply')
  expect.equal(value().title, original .. '\0\n', 'Apply sees the decoded bytes')
  expect.equal(value().callback, callback, 'opaque siblings preserve identity')
  row(state, 'sibling')
  expect.equal(state.text, '\\n literal', 'supported strings remain literal')
  expect.truthy(confirm(state, '\\xFF'), 'literal mode accepts backslashes without decoding')
  invoke(state, 'apply')
  expect.equal(value().sibling, '\\xFF', 'literal text remains literal')
  expect.equal(value().title, original .. '\0\n', 'other rows preserve the edited value')
  expect.equal(#testing.takeReports(), 0, 'string editing produces no reports')
  running.runtime:close()
end)

test('domain text changes preserve a draft until an explicit successful confirmation', function()
  local running, state, value = fixture()
  invoke(state, 'configure')
  row(state, 'count')
  local draft, edit = state.draft, state.edit
  controller.setText(state, 'not a number')
  expect.equal(state.draft, draft, 'typing does not rebuild the draft')
  expect.falsy(controller.confirmText(state), 'invalid parsing rejects confirmation')
  expect.equal(state.edit, edit, 'the rejected edit remains active')
  expect.equal(state.text, 'not a number', 'rejected text remains available')
  expect.truthy(state.message:find('finite number', 1, true), 'the parser diagnostic remains visible')
  controller.update(state)
  controller.graphCancel(state)
  expect.equal(state.edit, edit, 'updates and gesture cancellation retain the edit')
  state.close = function() end
  state.close()
  expect.equal(state.edit, edit, 'closing retains pending text')
  controller.setText(state, '6')
  expect.truthy(controller.confirmText(state), 'valid text confirms')
  expect.equal(value().count, 1, 'confirmation is not Apply')
  expect.equal(state.edit, nil, 'successful confirmation closes the field')
  invoke(state, 'apply')
  expect.equal(value().count, 6, 'Apply replaces the activation')
  invoke(state, 'configure')
  local model = state.draft
  local count = row(state, 'count')
  expect.truthy(state.edit, 'selecting a text row starts its edit')
  controller.setText(state, 'unconfirmed')
  invoke(state, 'clear')
  expect.equal(state.text, '', 'Clear changes only field text')
  expect.equal(state.draft, model, 'Clear does not rebuild the draft')
  invoke(state, 'confirm')
  expect.truthy(state.edit, 'a rejected Confirm keeps its field')
  invoke(state, 'cancel')
  expect.equal(state.edit, nil, 'Cancel closes the field')
  expect.equal(state.text, '', 'Cancel discards its text')
  expect.equal(state.row, nil, 'Cancel deselects the row so selecting it again restarts the edit')
  row(state, 'enabled')
  expect.equal(state.draft, model, 'selecting a boolean does not toggle')
  controller.toggle(state)
  invoke(state, 'apply')
  expect.equal(value().enabled, false, 'the value field toggles the boolean')
  controller.selectRow(state, -1)
  controller.choose(state, count, 999)
  expect.equal(state.edit, nil, 'invalid rows and choices do not start edits')
  running.runtime:close()
end)

test('stable action IDs reject disabled and unknown actions without reporting success', function()
  local running, state = fixture()
  local before = state.message
  expect.falsy(controller.invoke(state, 'enable'), 'already enabled entry')
  expect.falsy(controller.invoke(state, 'missing'), 'unknown action')
  expect.equal(state.message, before, 'rejected actions leave the message unchanged')
  local seen = {}
  for _, button in state.buttons do
    expect.truthy(button.id and not seen[button.id], 'each action has a unique explicit ID')
    seen[button.id] = true
  end
  expect.truthy(seen['clear-filter'] and seen['clear-selection'], 'graph reset controls are explicit')
  expect.equal(seen.load, nil, 'inspection does not show catalog actions')
  expect.equal(seen.add, nil, 'inspection does not show configuration actions')
  invoke(state, 'catalog')
  expect.truthy(state.actions.load, 'catalog Load has its own identity')
  expect.equal(state.actions.add, nil, 'catalog does not show configuration Add')
  invoke(state, 'configure')
  expect.truthy(state.actions.add, 'configuration Add has its own identity')
  expect.equal(state.actions.load, nil, 'configuration does not show catalog Load')
  running.runtime:close()

  local protectedRunning, protectedState = fixture(nil, nil, { protected = { 'editable' } })
  for _, id in { 'disable', 'reload', 'remove' } do
    controller.update(protectedState)
    local action
    for _, button in protectedState.buttons do
      if button.id == id then
        action = button
      end
    end
    expect.truthy(action, id .. ' is listed for a protected entry')
    expect.falsy(action.enabled, id .. ' is disabled for a protected entry')
  end
  expect.falsy(controller.invoke(protectedState, 'remove'), 'a protected Remove is rejected')
  protectedRunning.runtime:close()
end)

test('choice domain actions use immutable declared values rather than their labels', function()
  local running, state, value = fixture(schema.object {
    choice = schema.default(schema.union(schema.literal<<false>>(false), schema.literal<<'false'>> 'false'))(false),
  })
  invoke(state, 'configure')
  local index = row(state, 'choice')
  controller.choose(state, index, 2)
  invoke(state, 'apply')
  expect.equal(value().choice, 'false', 'a string choice keeps its actual type')
  controller.choose(state, index, 1)
  invoke(state, 'apply')
  expect.equal(value().choice, false, 'a false choice is not treated as absent')
  running.runtime:close()
end)

test('a refinement failure keeps the activation and each lifecycle action updates the entry', function()
  local running, state, value = fixture()
  invoke(state, 'configure')
  row(state, 'count')
  confirm(state, '-1')
  invoke(state, 'apply')
  expect.equal(value().count, 1, 'failed validation does not dispose')
  expect.truthy(state.message:find('count', 1, true), 'validation visible: ' .. state.message)
  local oldId = state.view.selection.id
  invoke(state, 'disable')
  expect.equal(running.service:entries()[2].enabled, false, 'disable intent')
  invoke(state, 'enable')
  expect.equal(running.service:entries()[2].state, 'active', 'reenable')
  invoke(state, 'reload')
  expect.equal(running.service:entries()[2].state, 'active', 'reload leaves the replacement active')
  invoke(state, 'remove')
  invoke(state, 'catalog')
  row(state, 'editable')
  invoke(state, 'load')
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

test('editor results replace the generic action message', function()
  local running, state = fixture()
  invoke(state, 'configure')
  row(state, 'enabled')
  controller.toggle(state)
  expect.truthy(state.message:find('Draft changed', 1, true), 'toggle status')
  invoke(state, 'reset')
  expect.truthy(state.message:find('Draft changed', 1, true), 'reset retains the editor status')
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no generic success replaces the editor status')
  running.runtime:close()

  local mapRunning, mapState, mapValue = fixture(schema.object {
    items = schema.default(schema.map(schema.number())) { existing = 2 },
  })
  invoke(mapState, 'configure')
  row(mapState, 'items')
  invoke(mapState, 'add')
  confirm(mapState, 'existing')
  expect.truthy(mapState.message:find('key already exists', 1, true), 'the rejection remains visible')
  expect.equal(mapState.message:find('Action completed', 1, true), nil, 'no generic success')
  invoke(mapState, 'apply')
  expect.equal(mapValue().items.existing, 2, 'the rejected add does not replace the entry')
  mapRunning.runtime:close()

  local setRunning, setState, setValue = fixture(schema.object {
    item = schema.optional(schema.union(schema.number(), schema.string())),
  })
  invoke(setState, 'configure')
  row(setState, 'item')
  invoke(setState, 'optional')
  expect.truthy(
    setState.message:find('cannot create an editable value', 1, true),
    'the seed rejection is visible: ' .. setState.message
  )
  expect.equal(setState.message:find('Action completed', 1, true), nil, 'no success message overwrites the rejection')
  invoke(setState, 'apply')
  expect.equal(setValue().item, nil, 'the rejected Set leaves the optional absent')
  setRunning.runtime:close()
end)

test('scrolling clamps both boundaries', function()
  local running, state = fixture()
  invoke(state, 'configure')
  row(state, 'count')
  controller.scrollBy(state, 10000)
  expect.equal(state.scroll, 1, 'scroll clamps to the last details line')
  controller.scrollBy(state, -10000)
  expect.equal(state.scroll, 0, 'scroll clamps to the first row')
  controller.scrollBy(state, 0 / 0)
  expect.equal(state.scroll, 0, 'nonfinite deltas cannot corrupt scrolling')
  running.runtime:close()
end)

return test
