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

local function row(state, label, activate)
  controller.update(state)
  if state.tab == 'catalog' then
    controller.selectCatalog(state, label)
    return
  end
  for index, current in state.editorRows do
    if current.label == label or current.label == string.format('%q', label) then
      controller.selectRow(state, index, activate ~= false)
      return index
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

local function confirm(state, text)
  controller.setText(state, text)
  return controller.confirmText(state)
end

local function panelPoint(state, point)
  return { x = point.x + state.graphBounds.x, y = point.y + state.graphBounds.y }
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

test('invalid numeric drafts retain applied activation and show parser diagnostics', function()
  local running, state, value = fixture()
  invoke(state, 'configure')
  row(state, 'count')
  confirm(state, '-1')
  invoke(state, 'apply')
  expect.equal(value().count, 1, 'failed validation does not dispose')
  expect.truthy(state.message:find('count', 1, true), 'validation visible: ' .. state.message)
  invoke(state, 'disable')
  expect.equal(running.service:entries()[2].enabled, false, 'disable intent')
  invoke(state, 'enable')
  expect.equal(running.service:entries()[2].state, 'active', 'reenable')
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
end)

test('removed entries can be loaded from the projected session catalog', function()
  local running, state = fixture()
  local oldId = state.view.selection.id
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

test('cancelling map Add cannot turn a later scalar edit into a map insertion', function()
  local running, state, value = fixture(schema.object {
    count = schema.default(schema.number())(1),
    items = schema.default(schema.map(schema.number())) { existing = 2 },
  })
  invoke(state, 'configure')
  row(state, 'items')
  invoke(state, 'add')
  controller.setText(state, 'cancelled')
  controller.cancelText(state)
  row(state, 'count')
  confirm(state, '4')
  invoke(state, 'apply')
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
  invoke(state, 'configure')
  row(state, 'items')
  invoke(state, 'add')
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
  running.runtime:close()
end)

test('editor button outcomes remain visible instead of becoming generic action success', function()
  local running, state = fixture()
  invoke(state, 'configure')
  row(state, 'enabled')
  expect.truthy(state.message:find('Draft changed', 1, true), 'toggle status')
  invoke(state, 'reset')
  expect.truthy(state.message:find('Draft changed', 1, true), 'reset retains the editor status')
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no generic success replaces the editor status')
  running.runtime:close()
end)

test('a collection with nonliteral union children cannot seed or report a successful Add', function()
  local running, state, value = fixture(schema.object {
    items = schema.default(schema.array(schema.union(schema.number(), schema.string()))) {},
  })
  invoke(state, 'configure')
  row(state, 'items')
  local before = state.message
  local add
  for _, button in state.buttons do
    if button.id == 'add' then
      add = button
    end
  end
  expect.equal(add.enabled, false, 'an unseedable child disables Add')
  expect.falsy(controller.invoke(state, 'add'), 'disabled Add is rejected')
  expect.equal(state.message, before, 'a rejected Add cannot report success')
  invoke(state, 'apply')
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
  for _, dimensions in { { 800, 472 }, { 2400, 120000 } } do
    local state = controller.new(running.service, {}, dimensions[1], dimensions[2])
    expect.equal(state.height, dimensions[2], 'usable dimensions are accepted')
  end
  running.runtime:close()
end)

test('duplicate map keys keep their rejection diagnostic and leave the draft unchanged', function()
  local running, state, value = fixture(schema.object {
    items = schema.default(schema.map(schema.number())) { existing = 2 },
  })
  invoke(state, 'configure')
  row(state, 'items')
  invoke(state, 'add')
  confirm(state, 'existing')
  expect.truthy(state.message:find('key already exists', 1, true), 'the rejection remains visible')
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no generic success')
  invoke(state, 'apply')
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

test('an unseedable optional Set keeps its editor rejection rather than reporting action success', function()
  local running, state, value = fixture(schema.object {
    item = schema.optional(schema.union(schema.number(), schema.string())),
  })
  invoke(state, 'configure')
  row(state, 'item')
  invoke(state, 'optional')
  expect.truthy(
    state.message:find('cannot create an editable value', 1, true),
    'the seed rejection is visible: ' .. state.message
  )
  expect.equal(state.message:find('Action completed', 1, true), nil, 'no success message overwrites the rejection')
  invoke(state, 'apply')
  expect.equal(value().item, nil, 'the rejected Set leaves the optional absent')
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
  for _, input in { '\n', '\t', utf8.char(0x85, 0x2028), string.char(255) } do
    controller.setText(state, input)
    expect.equal(state.text, encoded, 'unsafe direct text updates retain the representable field')
    expect.equal(state.draft, model, 'unsafe direct text updates retain the draft')
    expect.equal(state.edit, edit, 'unsafe direct text updates retain the operation')
    expect.truthy(#state.message > 0, 'the text-domain rejection is visible')
  end
  for _, input in { '\\', '\\q', '\\xGG' } do
    expect.falsy(confirm(state, input), 'malformed escapes reject confirmation')
    expect.equal(state.draft, model, 'rejection preserves the model')
    expect.equal(state.edit, edit, 'rejection preserves the edit target')
    expect.equal(state.text, input, 'rejected text stays editable')
    expect.truthy(state.message:find('escape', 1, true), 'the decoder diagnostic remains visible')
    controller.update(state)
    expect.truthy(state.message:find('escape', 1, true), 'updates retain the rejection')
  end
  local closed = 0
  state.close = function()
    closed += 1
  end
  invoke(state, 'close')
  expect.equal(closed, 1, 'Close remains reachable after rejection')
  expect.equal(state.edit, edit, 'Close retains the rejected operation')
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
  invoke(state, 'close')
  expect.equal(state.edit, edit, 'closing retains pending text')
  controller.setText(state, '6')
  expect.truthy(controller.confirmText(state), 'valid text confirms')
  expect.equal(value().count, 1, 'confirmation is not Apply')
  expect.equal(state.edit, nil, 'successful confirmation closes the field')
  invoke(state, 'apply')
  expect.equal(value().count, 6, 'Apply replaces the activation')
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
  expect.truthy(seen.load and seen.add, 'catalog Load and configuration Add have distinct identities')
  running.runtime:close()
end)

test('choice domain actions use immutable declared values rather than their labels', function()
  local running, state, value = fixture(schema.object {
    choice = schema.default(schema.union(schema.literal<<false>>(false), schema.literal<<'false'>> 'false'))(false),
  })
  invoke(state, 'configure')
  local index = row(state, 'choice', false)
  expect.truthy(table.isfrozen(state.editorRows[index].choices), 'declared choices are immutable')
  controller.choose(state, index, 2)
  invoke(state, 'apply')
  expect.equal(value().choice, 'false', 'a string choice keeps its actual type')
  controller.choose(state, index, 1)
  invoke(state, 'apply')
  expect.equal(value().choice, false, 'a false choice is not treated as absent')
  running.runtime:close()
end)

test('panel graph coordinates subtract the canvas origin and cannot begin on a toolbar', function()
  local running, state = fixture()
  local selection = state.view.selection
  local bounds = state.graphBounds
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
end)

test('pointer-anchored graph zoom translates panel coordinates before preserving the graph point', function()
  local running, state = fixture()
  local point = { x = 123, y = 210 }
  local before = graph.world(state.view.camera, point)
  controller.graphZoom(state, panelPoint(state, point), 1.2)
  local after = graph.world(state.view.camera, point)
  expect.near(after.x, before.x, 1e-8, 'the cursor graph x remains fixed')
  expect.near(after.y, before.y, 1e-8, 'the cursor graph y remains fixed')
  running.runtime:close()
end)

test('selecting rows without activation and explicit text actions preserve domain boundaries', function()
  local running, state, value = fixture()
  invoke(state, 'configure')
  local count = row(state, 'count', false)
  expect.equal(state.edit, nil, 'selection alone does not start an edit')
  local model = state.draft
  controller.selectRow(state, count, true)
  controller.setText(state, 'unconfirmed')
  invoke(state, 'clear')
  expect.equal(state.text, '', 'Clear changes only field text')
  expect.equal(state.draft, model, 'Clear does not rebuild the draft')
  invoke(state, 'confirm')
  expect.truthy(state.edit, 'a rejected Confirm keeps its field')
  invoke(state, 'cancel')
  expect.equal(state.edit, nil, 'Cancel closes the field')
  expect.equal(state.text, '', 'Cancel discards its text')
  local enabled = row(state, 'enabled', false)
  expect.equal(state.draft, model, 'selecting a boolean does not toggle')
  controller.selectRow(state, enabled, true)
  invoke(state, 'apply')
  expect.equal(value().enabled, false, 'explicit activation toggles the boolean')
  controller.selectRow(state, -1, true)
  controller.choose(state, count, 999)
  expect.equal(state.edit, nil, 'invalid rows and choices do not start edits')
  running.runtime:close()
end)

test('scrolling clamps both boundaries and retains pending text through updates', function()
  local running, state = fixture()
  invoke(state, 'configure')
  row(state, 'count')
  controller.setText(state, 'pending')
  local edit = state.edit
  controller.scrollBy(state, 10000)
  expect.equal(state.scroll, #state.editorRows - 1, 'scroll clamps to the last row')
  expect.equal(state.edit, edit, 'scroll does not cancel an edit')
  expect.equal(state.text, 'pending', 'scroll retains pending text')
  controller.scrollBy(state, -10000)
  expect.equal(state.scroll, 0, 'scroll clamps to the first row')
  controller.scrollBy(state, 0 / 0)
  expect.equal(state.scroll, 0, 'nonfinite deltas cannot corrupt scrolling')
  controller.graphPress(state, panelPoint(state, { x = 1, y = 1 }))
  controller.graphCancel(state)
  expect.equal(state.edit, edit, 'graph cancellation affects only its gesture')
  expect.equal(state.view.dragging, nil, 'graph capture ends')
  running.runtime:close()
end)

test('Fit after search uses the restored canvas and remains idempotent', function()
  local running, state = fixture()
  invoke(state, 'search')
  controller.setSearch(state, 'editable')
  invoke(state, 'fit')
  local first = state.view.camera
  local expected = graph.fit(state.view.layout, state.view.viewport)
  expect.near(first.x, expected.x, 1e-8, 'Fit uses the current canvas x')
  expect.near(first.y, expected.y, 1e-8, 'Fit uses the current canvas y')
  expect.near(first.zoom, expected.zoom, 1e-8, 'Fit uses the current canvas zoom')
  invoke(state, 'fit')
  expect.near(state.view.camera.x, first.x, 1e-8, 'a repeated Fit keeps camera x')
  expect.near(state.view.camera.y, first.y, 1e-8, 'a repeated Fit keeps camera y')
  expect.near(state.view.camera.zoom, first.zoom, 1e-8, 'a repeated Fit keeps zoom')
  running.runtime:close()
end)

test('selected boolean and choice fields reserve reachable bounds without text actions', function()
  local running, state = fixture(schema.object {
    enabled = schema.default(schema.boolean())(true),
    choice = schema.default(schema.union(schema.literal<<false>>(false), schema.literal<<'false'>> 'false'))(false),
  })
  state.width, state.height = 800, 472
  invoke(state, 'configure')
  for _, label in { 'enabled', 'choice' } do
    row(state, label, false)
    expect.equal(state.edit, nil, 'a value widget is not a text operation')
    expect.truthy(state.editBounds, 'the selected value has declared bounds')
    expect.truthy(state.bodyBounds.height >= 36, 'one configuration row remains reachable')
    expect.truthy(
      state.bodyBounds.y + state.bodyBounds.height <= state.editBounds.y,
      'the configuration rows do not overlap the value widget'
    )
    for _, button in state.buttons do
      expect.falsy(button.id == 'confirm' or button.id == 'cancel' or button.id == 'clear', 'no text-only actions')
    end
  end
  running.runtime:close()
end)

test('a pending graph click resolves the scene displayed at press rather than a refreshed camera', function()
  local running, state = fixture()
  local published = table.clone(state.view)
  local selected = state.view.selection.id
  local box = published.layout[selected]
  local point =
    panelPoint(state, graph.screen(published.camera, { x = box.x + box.width / 2, y = box.y + box.height / 2 }))
  state.view.selection = nil
  published.selection = nil
  controller.graphPress(state, point)
  state.view.camera = { x = published.camera.x + 10000, y = published.camera.y + 10000, zoom = published.camera.zoom }
  controller.graphRelease(state, point, published)
  expect.truthy(state.view.selection, 'the original visible node remains selected')
  expect.equal(state.view.selection.id, selected, 'the published identity is selected')
  running.runtime:close()
end)

return test
