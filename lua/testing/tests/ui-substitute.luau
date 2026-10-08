local testing = require '@testing'
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local surfaces = require '@lunette-contracts/surfaces'
local vrUi = require '@testing/vr-ui'
local substitute = require '../ui-substitute'
local regressions = require '../ui-substitute/regressions'
local expect = testing.expect
local suite = testing.suite()

local function populate(running)
  local state = { activations = 0, changes = {}, selections = {}, events = {}, draws = {} }
  state.consumer = running.session:use(plugin.define {
    name = 'testing/ui-contract-consumer',
    requires = { ui = ui.capability, focus = focus.capability },
    init = function(context)
      state.context = context
      state.service = context:require(ui.capability)
      state.source = context:require(focus.capability):newSource(context)
      state.panel = state.service:newPanel(context, {
        name = 'Contract controls',
        pose = lovr.math.newMat4():translate(0, 1.5, -2),
        width = 2,
        height = 1,
        logicalWidth = 400,
        logicalHeight = 200,
        theme = { rowHeight = 20, padding = 2, spacing = 2 },
      })
      state.button = state.panel:button(context, {
        id = 'activate',
        bounds = { x = 10, y = 10, width = 80, height = 30 },
        onActivate = function()
          state.activations += 1
        end,
        draw = function(pass, visual, defaultRenderer)
          state.draws[#state.draws + 1] = visual.id
          defaultRenderer(pass, visual)
        end,
      })
      state.field = state.panel:textField(context, {
        id = 'draft',
        bounds = { x = 100, y = 10, width = 180, height = 30 },
        value = 'draft',
        onChange = function(value)
          state.changes[#state.changes + 1] = value
        end,
        onSubmit = function(value)
          state.submitted = value
        end,
        onCancel = function(value)
          state.cancelled = value
        end,
        validate = function(value)
          return if value == 'bad' then 'Use another value.' else nil
        end,
      })
      state.choice = state.panel:choice(context, {
        id = 'choice',
        bounds = { x = 10, y = 50, width = 110, height = 100 },
        items = { { id = 'first', label = 'First' }, { id = 'second', label = 'Second' } },
        onChange = function(id)
          state.selections[#state.selections + 1] = id
        end,
      })
      local items = {}
      for index = 1, 20 do
        items[index] = { id = 'row-' .. index, label = 'Row ' .. index }
      end
      state.list = state.panel:list(context, {
        id = 'rows',
        bounds = { x = 130, y = 50, width = 110, height = 100 },
        items = items,
        onChange = function(id)
          state.selections[#state.selections + 1] = id
        end,
      })
      state.region = state.panel:region(context, {
        id = 'custom',
        bounds = { x = 250, y = 50, width = 180, height = 100 },
        items = {
          {
            id = 'node',
            label = 'Node',
            bounds = { x = 270, y = 60, width = 30, height = 30 },
            route = { { x = 280, y = 65 }, { x = 285, y = 80 } },
          },
        },
        onPointer = function(event)
          state.events[#state.events + 1] = event
        end,
        receiver = {
          key = function()
            return false
          end,
          text = function(value)
            state.regionText = value
            return true
          end,
        },
        wantsKeyboard = false,
      })
    end,
  })
  return state
end

local function withFixture(run)
  local running = vrUi.boot {
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    'theme',
    'laser',
    'keyboard',
    'desktop/pointing',
    { id = 'ui-substitute', definition = substitute.definition },
  }
  local ok, message = xpcall(function()
    run(running, populate(running))
  end, function(raised)
    return debug.traceback(tostring(raised), 2)
  end)
  local closed, cleanupMessage = pcall(function()
    running:close()
  end)
  if not ok then
    if not closed then
      message ..= '\nfixture cleanup: ' .. tostring(cleanupMessage)
    end
    error(message, 0)
  end
  if not closed then
    error(cleanupMessage, 0)
  end
end

local function test(name, run)
  suite(name, function()
    withFixture(run)
  end)
end

local function description(state, id)
  for _, control in state.panel:describe().controls do
    if control.id == id then
      return control
    end
  end
  error('missing control ' .. id)
end

local function key(state, code, modifiers)
  return state.source:key { code = code, modifiers = modifiers }
end

test('a public-contract consumer clicks independent controls through real VR pointers', function(running, state)
  running:clickControl(state.service, 'Contract controls', 'activate')
  expect.equal(state.activations, 1)
  state.button:setEnabled(false)
  expect.raises(function()
    running:clickControl(state.service, 'Contract controls', 'activate')
  end, 'enabled control')
  state.button:setEnabled(true)
  running:clickControl(state.service, 'Contract controls', 'choice')
  expect.equal(#description(state, 'choice').items, 2)
  running:clickControl(state.service, 'Contract controls', 'choice', 'right', 'second')
  expect.equal(state.choice:selected(), 'second')
  expect.equal(state.selections[1], 'second')
  expect.equal(#description(state, 'choice').items, 0)
  running:clickControl(state.service, 'Contract controls', 'custom', 'right', 'node')
  expect.truthy(state.events[#state.events].kind == 'release')
  expect.equal(state.source:text('custom text').kind, 'consumed')
  expect.equal(state.regionText, 'custom text')
  expect.equal(state.panel:describe().generation.kind, 'ui-generation')
end)

test('local focus sources edit native grapheme boundaries without printable key synthesis', function(running, state)
  local codes = lunette.keyCodes()
  running:clickControl(state.service, 'Contract controls', 'draft')
  expect.equal(key(state, codes.a).kind, 'unhandled')
  expect.equal(state.field:value(), 'draft')
  expect.equal(key(state, codes.a, { 'control' }).kind, 'consumed')
  local cluster = 'e' .. utf8.char(0x301)
  expect.equal(state.source:text(cluster).kind, 'consumed')
  expect.equal(state.field:value(), cluster)
  local caret, anchor = state.field:selection()
  expect.equal(caret, #cluster + 1)
  expect.equal(anchor, caret)
  expect.raises(function()
    state.field:setSelection(2)
  end, 'boundary')
  expect.equal(key(state, codes.backspace).kind, 'consumed')
  expect.equal(state.field:value(), '')
  state.field:setValue 'bad'
  key(state, codes.enter)
  expect.equal(state.submitted, nil, 'validation prevents submission')
  state.field:setValue 'ready'
  key(state, codes.enter)
  expect.equal(state.submitted, 'ready')
  key(state, codes.escape)
  expect.equal(state.cancelled, 'ready')
  expect.equal(state.source:text('unfocused').kind, 'unhandled')
  expect.equal(#state.changes, 2, 'programmatic changes do not echo')
end)

test(
  'editing preserves native boundaries for representative graphemes and rejects invalid selection atomically',
  function(_, state)
    local clusters = {
      '界',
      'e' .. utf8.char(0x301),
      utf8.char(0x1f44d, 0x1f3fd),
      utf8.char(0x1f1ec, 0x1f1e7),
      utf8.char(0x1f469, 0x200d, 0x1f4bb),
      utf8.char(0x1100, 0x1161, 0x11a8),
      utf8.char(0x915, 0x94d, 0x937),
    }
    expect.truthy(state.field:focus())
    for _, cluster in clusters do
      state.field:setValue('x' .. cluster .. 'y')
      state.field:setSelection(#cluster + 2)
      key(state, lunette.keyCodes().backspace)
      expect.equal(state.field:value(), 'xy', 'backspace removes a whole cluster')
      local caret, anchor = state.field:selection()
      expect.truthy(table.find(lunette.textBoundaries(state.field:value()), caret))
      expect.equal(anchor, caret)
      state.field:setValue(cluster)
      state.field:setSelection(1, #cluster + 1)
      expect.equal(state.source:text('replacement').kind, 'consumed')
      expect.equal(state.field:value(), 'replacement')
    end
    state.field:setValue('e' .. utf8.char(0x301))
    state.field:setSelection(1)
    expect.raises(function()
      state.field:setSelection(2)
    end, 'boundary')
    expect.equal(state.field:selection(), 1)
    expect.raises(function()
      state.field:setValue 'invalid\nline'
    end, 'single%-line')
    expect.equal(state.field:value(), 'e' .. utf8.char(0x301))
  end
)

test('list descriptions retain ids while scroll and clipping change current hit bounds', function(running, state)
  local initial = description(state, 'rows')
  expect.equal(initial.items[1].id, 'row-1')
  state.list:scroll(10000)
  local current = description(state, 'rows')
  expect.equal(current.items[#current.items].id, 'row-20')
  running:clickControl(state.service, 'Contract controls', 'rows', 'right', 'row-20')
  expect.equal(state.list:selected(), 'row-20')
  state.list:setItems { { id = 'row-20', label = 'Retained' }, { id = 'other', label = 'Other' } }
  expect.equal(state.list:selected(), 'row-20')
  state.list:scroll(-10000)
  expect.equal(description(state, 'rows').items[1].label, 'Retained')
  expect.equal(initial.items[1].label, 'Row 1', 'previous descriptions are detached')
  local region = description(state, 'custom')
  expect.equal(region.bounds.width, 150, 'the panel clips the overflowing control')
  expect.equal(region.items[1].id, 'node')
  expect.equal(#region.items[1].route, 2)
  state.list:setItems {}
  expect.equal(state.list:selected(), nil)
  expect.equal(#description(state, 'rows').items, 0)
end)

test('renderer hooks are attributed to consumers and restore the caller pass after failure', function(running, state)
  local recorder = running.native.events.render
  local checkpoint = recorder:checkpoint()
  state.panel:draw(recorder.pass)
  recorder:assertRestored(checkpoint)
  expect.equal(state.draws[1], 'activate')
  local firstReport = #running.native.events.reported
  state.panel:button(state.context, {
    id = 'broken-draw',
    bounds = { x = 10, y = 160, width = 50, height = 20 },
    onActivate = function() end,
    draw = function(pass)
      pass:setColor(1, 0, 0, 1)
      pass:translate(9, 9, 9)
      error 'substitute hook failure'
    end,
  })
  state.panel:draw(recorder.pass)
  recorder:assertRestored(checkpoint)
  local reports = running.native.events.reported
  local messages = {}
  for index = firstReport + 1, #reports do
    messages[#messages + 1] = reports[index].message
  end
  expect.equal(#reports - firstReport, 1, table.concat(messages, '\n'))
  local reported = reports[firstReport + 1]
  expect.truthy(reported.message:find 'testing/ui%-contract%-consumer')
  expect.truthy(reported.message:find 'substitute hook failure')
  expect.truthy(reported.traceback:find 'ui%-substitute.luau')
  expect.equal(#testing.takeReports(), 0, 'a protected hook error is not a plugin lifecycle failure')
end)

test('hiding and removing captured regions cancel without activating release', function(running, state)
  local panel, region = running:discover(state.service, 'Contract controls', 'custom', 'node')
  running:aim(panel, region.bounds.x + 5, region.bounds.y + 5)
  running:step()
  running:button('right', 'trigger', true)
  running:step()
  state.panel:setVisible(false)
  local cancellations, releases = 0, 0
  for _, event in state.events do
    if event.kind == 'cancel' then
      cancellations += 1
      expect.equal(event.reason, 'hidden')
    end
    if event.kind == 'release' then
      releases += 1
    end
  end
  expect.equal(cancellations, 1)
  expect.equal(releases, 0)
  running:button('right', 'trigger', false)
  running:step()
  state.panel:setVisible(true)
  state.region:destroy()
  expect.truthy(state.region.dead)
  expect.falsy(state.region:destroy())
end)

test(
  'owner teardown and provider recovery invalidate retained handles and generation identity',
  function(running, state)
    local oldPanel, oldField, oldSource, oldService = state.panel, state.field, state.source, state.service
    local generation = oldPanel:describe().generation
    local oldPanels = oldService.panels
    local second = state.service:newPanel(state.context, {
      name = 'Same activation',
      width = 1,
      height = 1,
      logicalWidth = 100,
      logicalHeight = 100,
    })
    expect.equal(second:describe().generation, generation)
    running.session.instances['ui-substitute']:disable()
    expect.truthy(oldPanel.dead)
    expect.truthy(oldField.dead)
    expect.truthy(oldSource.dead)
    expect.raises(function()
      oldService:panels()
    end, 'no longer available')
    expect.equal(#oldPanels(oldService), 0, 'a captured query method sees no live panels')
    expect.falsy(oldField:focus())
    oldField:setValue 'ignored'
    expect.equal(oldField:value(), 'draft')
    expect.equal(#running.session:observe(surfaces.capability).service:all(), 0)
    running.session.instances['ui-substitute']:enable()
    expect.truthy(state.panel:describe().generation ~= generation, 'a recovered activation has a fresh token')
    expect.falsy(state.panel.dead)
    running:clickControl(state.service, 'Contract controls', 'activate')
    expect.equal(state.activations, 1)
    state.consumer:disable()
    expect.truthy(state.panel.dead)
    expect.truthy(state.button.dead)
  end
)

suite('fixture cleanup releases a frame activation even when an assertion fails', function()
  local retained
  expect.raises(function()
    withFixture(function(_, state)
      retained = state.panel
      expect.equal(false, true, 'intentional case assertion')
    end)
  end, 'intentional case assertion')
  expect.truthy(retained.dead, 'the failed case releases its panel')
  withFixture(function(running, state)
    running:clickControl(state.service, 'Contract controls', 'activate')
    expect.equal(state.activations, 1, 'a fresh frame activation receives input after failed-case cleanup')
  end)
end)

regressions.register(test)

return suite
