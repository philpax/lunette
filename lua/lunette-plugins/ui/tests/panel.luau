local testing = require '@testing'
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local ui = require '@lunette-contracts/ui'
local surfaces = require '@lunette-contracts/surfaces'
local expect = testing.expect
local fixture = require './support/panel'
local test = testing.suite()

local function click(state, id, hand, item)
  state.fixture:clickControl(state.service, 'public-ui-form', id, hand, item)
end

local function release(state, hand)
  state.fixture:button(hand or 'right', 'trigger', false)
  state.fixture:step()
end

local function kinds(events, kind)
  local result = {}
  for _, event in events do
    if event.kind == kind then
      result[#result + 1] = event
    end
  end
  return result
end

test('buttons, choices, and lists respond to VR pointer input', function()
  local state = fixture.boot()
  click(state, 'run')
  expect.equal(#state.activations, 1, 'primary release activates once')
  click(state, 'choice')
  click(state, 'choice', nil, 'item-1')
  expect.equal(state.chosen, 'item-1', 'visible choice option selects')
  click(state, 'list', nil, 'item-1')
  expect.equal(state.listed, 'item-1', 'visible list row selects')
  fixture.scroll(state, 'list', -1)
  local _, list = state.fixture:discover(state.service, 'public-ui-form', 'list')
  local item = list.items[#list.items]
  expect.truthy(list.items[1].id ~= 'item-1', 'pointer scroll advances the viewport')
  click(state, 'list', nil, item.id)
  expect.equal(state.listed, item.id, 'a scrolled row selects')
end)

test('disabling, hiding, tracking loss, or removing a control cancels its held gesture', function()
  local state = fixture.boot()
  fixture.press(state, 'run')
  state.button:setEnabled(false)
  release(state)
  expect.equal(#state.activations, 0, 'disable cancels instead of activating')
  state.button:setEnabled(true)
  fixture.press(state, 'custom')
  state.panel:setVisible(false)
  expect.equal(kinds(state.events, 'cancel')[1].reason, 'hidden')
  state.panel:setVisible(true)
  release(state)
  fixture.press(state, 'custom')
  state.fixture:tracked('right', false)
  state.fixture:step()
  expect.equal(kinds(state.events, 'cancel')[2].reason, 'tracking-loss')
  state.fixture:tracked('right', true)
  release(state)
  fixture.press(state, 'custom')
  state.region:destroy()
  expect.equal(#kinds(state.events, 'cancel'), 3, 'removal cancels immediately')
  release(state)
  expect.equal(#kinds(state.events, 'release'), 0, 'no cancelled gesture releases')
end)

test('provider withdrawal invalidates handles and recovery reconnects the same consumers', function()
  local state = fixture.boot()
  local first = state.panel:describe()
  click(state, 'draft')
  fixture.press(state, 'run')
  local panel, field, button = state.panel, state.field, state.button
  state.fixture.session.instances.ui:disable()
  expect.truthy(panel.dead and field.dead and button.dead, 'withdrawal invalidates retained handles')
  expect.equal(state.focus.service:focused(), nil, 'withdrawal clears local routing')
  state.fixture.session.instances.ui:enable()
  expect.truthy(first.generation ~= state.panel:describe().generation, 'recovery changes the generation')
  state.fixture:step()
  release(state)
  expect.equal(#state.activations, 0, 'the held trigger cannot activate a replacement control')
  click(state, 'run')
  expect.equal(#state.activations, 1, 'the same consumer reconnects after replacement')
end)

test('owner teardown invalidates its controls without calling it back', function()
  local state = fixture.boot()
  local control
  local instance = state.fixture.session:use(adapter.define {
    name = 'testing/capture-owner',
    requires = { ui.capability },
    init = function(context)
      control = state.panel:region(context, {
        id = 'owned',
        bounds = { x = 10, y = 260, width = 370, height = 30 },
        z = 1,
        onPointer = function(event)
          state.events[#state.events + 1] = { kind = event.kind }
        end,
      })
    end,
  })
  fixture.press(state, 'owned')
  local before = #state.events
  instance:disable()
  expect.truthy(control.dead, 'the region dies with its owner')
  expect.falsy(state.panel.dead, 'the panel owner keeps its panel')
  expect.equal(#state.events, before, 'the ended owner receives no cancellation')
  release(state)
  expect.equal(#kinds(state.events, 'release'), 0, 'the ended owner receives no release')
end)

test('text field edits, submits, and cancels through the virtual keyboard', function()
  local state = fixture.boot { keyboard = true }
  click(state, 'draft')
  local focused = state.focus.service:focused()
  expect.truthy(focused, 'the field takes local focus')
  fixture.key(state, 5)
  expect.equal(state.field:value(), 'é👩🏽‍💻', 'whole clusters are committed')
  fixture.key(state, 2)
  expect.equal(state.field:value(), 'é', 'backspace removes one grapheme')
  click(state, 'run')
  expect.equal(state.focus.service:focused(), focused, 'a button preserves field focus')
  fixture.key(state, 3)
  expect.equal(state.submits[1], 'é', 'Enter submits')
  fixture.key(state, 4)
  expect.equal(state.cancels[1], 'é', 'Escape cancels without discarding the draft')
  expect.equal(state.focus.service:focused(), nil, 'cancel ends editing')
  click(state, 'draft')
  state.panel:setVisible(false)
  expect.equal(state.focus.service:focused(), nil, 'hiding blurs')
  expect.equal(#state.fixture:nativeCalls 'key', 0, 'local keyboard input never reaches an application')
end)

test('panel motion and resizing preserve input', function()
  local state = fixture.boot()
  fixture.press(state, 'run')
  local before = state.panel:describe()
  state.panel:setPose(lovr.math.newMat4(table.unpack(before.pose)):translate(0.2, 0, 0))
  local moved, button = state.fixture:discover(state.service, 'public-ui-form', 'run')
  expect.truthy(moved.revision > before.revision, 'motion changes the revision')
  state.fixture:aim(moved, button.bounds.x + 5, button.bounds.y + 5)
  state.fixture:step()
  release(state)
  expect.equal(#state.activations, 1, 'a capture survives rigid motion')
  local offered = state.fixture.session:observe(surfaces.capability).service:all()[1]
  offered:setSize(before.width * 1.5)
  local after = state.panel:describe()
  expect.near(after.height, before.height * 1.5, 1e-5, 'resizing scales both world dimensions')
  expect.equal(after.logicalWidth, before.logicalWidth, 'logical layout is unchanged')
  click(state, 'run')
  expect.equal(#state.activations, 2, 'resized geometry remains accessible')
end)

test('painting and pointer picking share overlap order', function()
  for _, equalZ in { false, true } do
    local state = fixture.boot()
    local painted, activated = {}, {}
    for index, id in { 'first', 'second' } do
      state.panel:button(state.owner, {
        id = id,
        bounds = { x = 300, y = 10, width = 40, height = 30 },
        z = if equalZ then 2 elseif index == 1 then 10 else -1,
        onActivate = function()
          activated[#activated + 1] = id
        end,
        draw = function(pass, visual, base)
          painted[#painted + 1] = visual.id
          base(pass, visual)
        end,
      })
    end
    state.panel:draw(state.fixture.native.events.pass)
    local top = if equalZ then 'second' else 'first'
    expect.equal(painted[#painted], top, 'the winning control paints last')
    state.fixture:click(state.panel:describe(), 320, 25)
    expect.equal(table.concat(activated, ','), top, 'the pointer activates the last painted control')
    state.fixture:close()
  end
end)

test('themes and draw hooks change rendering without changing input', function()
  local heard = {}
  local state = fixture.boot {
    theme = { background = { 0.9, 0.1, 0.7, 1 }, rowHeight = 35 },
    draw = function(pass, visual, base)
      heard[#heard + 1] = visual
      base(pass, visual)
    end,
  }
  click(state, 'run')
  expect.equal(#state.activations, 1, 'custom rendering preserves input')
  state.field:focus()
  fixture.press(state, 'run')
  local selection = state.themes:select(state.owner, { colors = { control = { 0.2, 0.7, 0.8, 1 } } })
  state.fixture:draw()
  local pressed, focused = false, false
  for _, visual in heard do
    expect.equal(visual.theme.rowHeight, 35, 'panel theme reaches controls')
    pressed = pressed or (visual.id == 'run' and visual.pressed and visual.theme.control[1] == 0.2)
    focused = focused or (visual.id == 'draft' and visual.focused and visual.theme.control[1] == 0.2)
  end
  expect.truthy(pressed and focused, 'a live palette update keeps pressed and focused state')
  release(state)
  expect.equal(#state.activations, 2, 'the held gesture survives the palette update')
  selection:dispose()
end)

return test
