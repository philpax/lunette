local testing = require '@testing'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local surfaces = require '@lunette-contracts/surfaces'
local expect = testing.expect
local fixture = require './support/panel'
local test = testing.suite()

local function click(state, id, hand, item)
  state.fixture:clickControl(state.service, 'public-ui-form', id, hand, item)
end

local function kinds(events, kind)
  local result = {}
  for _, event in ipairs(events) do
    if event.kind == kind then
      result[#result + 1] = event
    end
  end
  return result
end

test('widgets button choice list VR scenario', function()
  local state = fixture.boot()
  click(state, 'run')
  expect.equal(#state.activations, 1, 'primary release activates once')
  local description, run = state.fixture:discover(state.service, 'public-ui-form', 'run')
  state.fixture:aim(description, run.bounds.x + 5, run.bounds.y + 5)
  state.fixture:button('right', 'a', true)
  state.fixture:step()
  state.fixture:button('right', 'a', false)
  state.fixture:step()
  expect.equal(#state.activations, 1, 'secondary input does not activate')
  click(state, 'choice')
  click(state, 'choice', nil, 'item-1')
  expect.equal(state.chosen, 'item-1', 'visible choice option selects')
  click(state, 'list', nil, 'item-1')
  expect.equal(state.listed, 'item-1', 'visible list row selects')
  expect.raises(function()
    click(state, 'list', nil, 'item-20')
  end, 'control', 'offscreen rows have no hit description')
  fixture.scroll(state, 'list', -1)
  local _, list = state.fixture:discover(state.service, 'public-ui-form', 'list')
  expect.truthy(list.items[1].id ~= 'item-1', 'real pointer scroll advances the viewport')
  local item = list.items[#list.items]
  click(state, 'list', nil, item.id)
  expect.equal(state.listed, item.id, 'rediscovered scrolled row selects')
end)

test('widgets dynamic removal and capture isolation', function()
  local state = fixture.boot()
  fixture.press(state, 'run', 'right')
  state.button:setEnabled(false)
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  expect.equal(#state.activations, 0, 'disable cancels instead of activating')
  state.button:setEnabled(true)
  fixture.press(state, 'run', 'right')
  fixture.press(state, 'run', 'left')
  state.fixture:button('left', 'trigger', false)
  state.fixture:step()
  expect.equal(#state.activations, 0, 'exclusive control ignores the other pointer release')
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  expect.equal(#state.activations, 1, 'the original pointer alone activates')
  fixture.press(state, 'custom', 'right')
  state.region:destroy()
  expect.equal(#kinds(state.events, 'cancel'), 1, 'control removal sends immediate cancellation')
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  expect.equal(#kinds(state.events, 'release'), 0, 'removed control receives no activating release')
end)

test('provider withdrawal invalidates handles and recovery reconnects the same consumers', function()
  local state = fixture.boot()
  local first = state.panel:describe()
  state.fixture:clickControl(state.service, 'public-ui-form', 'draft')
  expect.truthy(state.focus.service:focused(), 'the field holds local focus')
  fixture.press(state, 'run')
  local panel, field, button = state.panel, state.field, state.button
  local eventCount = #state.events
  state.fixture.session.instances.ui:disable()
  expect.truthy(panel.dead and field.dead and button.dead, 'provider withdrawal invalidates retained handles')
  expect.equal(state.focus.service:focused(), nil, 'withdrawal clears local routing')
  expect.equal(#state.events, eventCount, 'withdrawal never invokes a callback belonging to an ended consumer')
  state.fixture.session.instances.ui:enable()
  expect.truthy(first.generation ~= state.panel:describe().generation, 'recovery changes public generation')
  state.fixture:step()
  expect.equal(#state.activations, 0, 'the held trigger cannot activate a replacement control')
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  click(state, 'run')
  expect.equal(#state.activations, 1, 'the same consumer reconnects after replacement')
end)

test('panel descriptions report current geometry and half-open control bounds', function()
  local state = fixture.boot()
  local old = state.panel:describe()
  state.button:setBounds { x = 10, y = 10, width = 0, height = 40 }
  local nextDescription = state.panel:describe()
  expect.truthy(nextDescription.revision > old.revision, 'explicit geometry changes revision')
  expect.equal(nextDescription.controls[1].bounds, nil, 'zero-area control has no hit bounds')
  expect.raises(function()
    click(state, 'run')
  end, 'hit bounds', 'zero-area controls cannot be clicked')
  expect.raises(function()
    state.panel:button(
      state.owner,
      { id = 'draft', bounds = { x = 0, y = 0, width = 1, height = 1 }, onActivate = function() end }
    )
  end, 'duplicate', 'control ids cannot shadow')
  expect.raises(function()
    state.button:setBounds { x = 0, y = 0, width = -1, height = 1 }
  end, 'bounds', 'negative size fails')
end)

test('text field VR edit submit cancel', function()
  local state = fixture.boot { keyboard = true }
  click(state, 'draft')
  local focused = state.focus.service:focused()
  expect.truthy(focused, 'primary field interaction selects a local route')
  fixture.key(state, 5)
  expect.equal(state.field:value(), 'é👩🏽‍💻', 'the real virtual keyboard delivers whole committed clusters')
  fixture.key(state, 2)
  expect.equal(state.field:value(), 'é', 'backspace removes one extended grapheme')
  click(state, 'run')
  expect.equal(state.focus.service:focused(), focused, 'nontext button preserves field focus')
  fixture.key(state, 3)
  expect.equal(state.submits[1], 'é', 'keyboard Enter submits the draft')
  fixture.key(state, 4)
  expect.equal(state.cancels[1], 'é', 'keyboard Escape cancels without discarding the draft')
  expect.equal(state.focus.service:focused(), nil, 'cancel ends editing')
  click(state, 'draft')
  expect.truthy(state.focus.service:focused(), 'pointer resumes retained editing')
  state.panel:setVisible(false)
  expect.equal(state.focus.service:focused(), nil, 'hiding blurs immediately')
  expect.equal(state.field:value(), 'é', 'hide retains the draft')
  expect.equal(#state.fixture:nativeCalls 'key', 0, 'local keyboard input never leaks to an application')
  expect.equal(state.fixture:keyboardCount(), 1, 'one actual keyboard is used')
end)

test('panel hide tracking loss and theme replacement cancel active gestures', function()
  local state = fixture.boot()
  fixture.press(state, 'custom', 'right')
  state.panel:setVisible(false)
  expect.equal(kinds(state.events, 'cancel')[1].reason, 'hidden', 'hide cancels synchronously')
  state.panel:setVisible(true)
  state.fixture:step()
  expect.equal(#kinds(state.events, 'press'), 1, 'held trigger cannot reactivate after hide')
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  fixture.press(state, 'custom', 'right')
  state.fixture:tracked('right', false)
  state.fixture:step()
  expect.equal(kinds(state.events, 'cancel')[2].reason, 'tracking-loss', 'real tracking loss cancels')
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  fixture.press(state, 'custom', 'right')
  local revision = state.panel:describe().revision
  state.panel:setTheme { rowHeight = 35 }
  expect.truthy(state.panel:describe().revision > revision, 'theme replacement increments revision')
  expect.equal(
    kinds(state.events, 'cancel')[3].reason,
    'control-removed',
    'theme replacement cancels incompatible gestures'
  )
end)

test('rigid panel motion preserves a held pointer capture', function()
  local state = fixture.boot()
  fixture.press(state, 'custom')
  local before = state.panel:describe()
  local pose = lovr.math.newMat4(table.unpack(before.pose)):translate(0.2, 0, 0)
  state.panel:setPose(pose)
  local after = state.panel:describe()
  expect.truthy(after.revision > before.revision, 'the moved geometry has a new revision')
  for _, event in state.events do
    expect.falsy(event.kind == 'cancel', 'rigid movement does not cancel a capture')
  end
  local _, control = state.fixture:discover(state.service, 'public-ui-form', 'custom')
  local bounds = control.bounds
  state.fixture:aim(after, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
  state.fixture:step()
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  local releases = 0
  for _, event in state.events do
    if event.kind == 'release' then
      releases += 1
      expect.truthy(event.captured, 'the original gesture remains captured')
      expect.truthy(event.inside, 'release uses the moved panel hit geometry')
    end
  end
  expect.equal(releases, 1, 'one original gesture releases after motion')
  fixture.press(state, 'run')
  state.panel:setPose(lovr.math.newMat4(pose):translate(0.2, 0, 0))
  local moved, button = state.fixture:discover(state.service, 'public-ui-form', 'run')
  local buttonBounds = button.bounds
  state.fixture:aim(moved, buttonBounds.x + buttonBounds.width / 2, buttonBounds.y + buttonBounds.height / 2)
  state.fixture:step()
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  expect.equal(#state.activations, 1, 'an original button capture remains eligible after rigid motion')
  click(state, 'run')
  expect.equal(#state.activations, 2, 'new interaction uses the moved geometry')
end)

test('control-local cancellation preserves another pointer capture and suppresses a held trigger', function()
  local state = fixture.boot()
  fixture.press(state, 'run', 'left')
  fixture.press(state, 'custom', 'right')
  state.button:setEnabled(false)
  state.button:setEnabled(true)
  state.fixture:step()
  expect.equal(#state.activations, 0, 'a held trigger cannot reactivate after local cancellation')
  expect.equal(#kinds(state.events, 'cancel'), 0, 'the other control stays captured')
  state.fixture:button('left', 'trigger', false)
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  expect.equal(#state.activations, 0, 'the cancelled control cannot activate on release')
  expect.equal(#kinds(state.events, 'release'), 1, 'the other capture releases normally')
  fixture.press(state, 'run', 'left')
  state.fixture:button('left', 'trigger', false)
  state.fixture:step()
  expect.equal(#state.activations, 1, 'a new trigger edge can activate again')
end)

test('owner teardown during a capture invalidates its control and never calls back the ended owner', function()
  local state = fixture.boot()
  local owner, control
  local instance = state.fixture.session:use(plugin.define {
    name = 'testing/capture-owner',
    requires = { ui = ui.capability },
    init = function(context)
      owner = context
      control = state.panel:region(context, {
        id = 'owned',
        bounds = { x = 10, y = 260, width = 370, height = 30 },
        z = 1,
        onPointer = function(event)
          state.events[#state.events + 1] = { id = 'owned', kind = event.kind }
        end,
      })
    end,
  })
  fixture.press(state, 'owned', 'right')
  local before = #state.events
  instance:disable()
  expect.falsy(owner:active(), 'the region owner ended')
  expect.truthy(control.dead, 'owner teardown invalidates its region')
  expect.falsy(state.panel.dead, 'the other owner retains its panel')
  expect.equal(#state.events, before, 'an ended owner receives no terminal callback')
  state.fixture:button('right', 'trigger', false)
  state.fixture:step()
  expect.equal(#kinds(state.events, 'release'), 0, 'the ended owner receives no stale release')
end)

test('painting and real pointer picking share overlap order', function()
  for _, equalZ in ipairs { false, true } do
    local state = fixture.boot()
    local painted, activated = {}, {}
    for index, id in ipairs { 'first', 'second' } do
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
    local description = state.panel:describe()
    expect.equal(description.controls[#description.controls].id, top, 'descriptions use the same control order')
    state.fixture:click(description, 320, 25)
    expect.equal(table.concat(activated, ','), top, 'the actual pointer activates the last painted control')
    state.fixture:close()
  end
end)

test('control ids are unique per owner and owner or provider replacement renews identity', function()
  local state = fixture.boot()
  local other = {}
  other.instance = state.fixture.session:use(plugin.define {
    name = 'testing/ui-second-owner',
    requires = { ui = ui.capability },
    init = function(context)
      other.owner = context
    end,
  })
  local picked = {}
  local function shared(owner, x, name)
    return state.panel:button(owner, {
      id = 'shared',
      bounds = { x = x, y = 10, width = 30, height = 30 },
      onActivate = function()
        picked[#picked + 1] = name
      end,
    })
  end
  local first = shared(state.owner, 300, 'first')
  local second = shared(other.owner, 340, 'second')
  expect.truthy(first.owner ~= second.owner, 'owner identities are distinct')
  expect.raises(function()
    shared(state.owner, 340, 'again')
  end, 'duplicate', 'one owner cannot reuse an id in the same panel')
  local otherPanel = state.service:newPanel(state.owner, {
    name = 'second-panel',
    pose = lovr.math.newMat4():translate(0, 1.5, -2),
    width = 2,
    height = 1,
    logicalWidth = 200,
    logicalHeight = 100,
  })
  expect.raises(function()
    otherPanel:button(state.owner, {
      id = 'shared',
      bounds = { x = 10, y = 10, width = 30, height = 30 },
      onActivate = function() end,
    })
  end, 'duplicate', 'same-owner ids are provider-wide')
  state.fixture:clickControl(state.service, 'public-ui-form', 'shared', nil, nil, first.owner)
  state.fixture:clickControl(state.service, 'public-ui-form', 'shared', nil, nil, second.owner)
  expect.equal(table.concat(picked, ','), 'first,second', 'token-selected VR clicks reach the actual owner')
  other.instance:reload {}
  expect.truthy(second.dead, 'owner replacement ends its controls')
  local renewed = shared(other.owner, 340, 'renewed')
  expect.truthy(renewed.owner ~= second.owner, 'owner replacement renews identity')
  state.fixture.session.instances.ui:reload {}
  expect.truthy(first.dead, 'provider replacement ends retained controls')
  local again = state.panel:button(state.owner, {
    id = 'shared',
    bounds = { x = 300, y = 10, width = 30, height = 30 },
    onActivate = function() end,
  })
  expect.truthy(again.owner ~= first.owner, 'provider replacement renews identity')
end)

test('a UI panel offers a live surface whose hit geometry follows its world size', function()
  local state = fixture.boot()
  local observed = state.fixture.session:observe(surfaces.capability)
  local all = observed.service:all()
  expect.equal(#all, 1, 'one panel surface is offered')
  local offered = all[1]
  expect.falsy(offered.dead, 'the visible offered surface is live')
  expect.truthy(offered.onPointer, 'pointer handler is offered')
  local description, control = state.fixture:discover(state.service, 'public-ui-form', 'run')
  local bounds = control.bounds
  state.fixture:aim(description, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
  local hand = state.fixture.native.events.controllers.right
  local x, y, distance = offered:raycast(hand.origin, hand.direction)
  expect.near(x, 50, 0.001, 'public geometry and raycast x agree')
  expect.near(y, 30, 0.001, 'public geometry and raycast y agree')
  expect.near(distance, 1, 0.001, 'the ray reaches the panel')
  click(state, 'run')
  expect.equal(#state.activations, 1, 'actual pointer activates the offered button')
  local before = state.panel:describe()
  offered:setSize(before.width * 1.5)
  local after = state.panel:describe()
  expect.near(after.width, before.width * 1.5, 1e-5)
  expect.near(after.height, before.height * 1.5, 1e-5, 'the grab adapter scales both world dimensions')
  expect.equal(after.logicalWidth, before.logicalWidth, 'logical controls are not relaid out')
  expect.equal(after.logicalHeight, before.logicalHeight)
  click(state, 'run')
  expect.equal(#state.activations, 2, 'resized geometry remains controller accessible')
end)

test('UI theme and draw hook theming preserves input', function()
  local heard = {}
  local state = fixture.boot {
    theme = { background = { 0.9, 0.1, 0.7, 1 }, foreground = { 0, 0, 0, 1 }, rowHeight = 35 },
    draw = function(pass, visual, base)
      heard[#heard + 1] = visual
      base(pass, visual)
      if visual.kind == 'button' then
        pass:setColor(0.1, 0.8, 0.2, 1)
        local bounds = visual.clip
        pass:plane(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0.001, bounds.width, bounds.height)
      end
    end,
  }
  local before = state.panel:describe()
  click(state, 'run')
  expect.equal(#state.activations, 1, 'custom rendering preserves real enabled-control input')
  state.fixture:draw()
  local after = state.panel:describe()
  expect.equal(before.controls[1].bounds.x, after.controls[1].bounds.x, 'drawing does not move input')
  local button
  for _, visual in ipairs(heard) do
    if visual.id == 'run' then
      button = visual
    end
  end
  expect.truthy(button, 'panel hook receives control visual state')
  expect.equal(button.theme.background[1], 0.9, 'altered panel colour reaches rendering')
  expect.equal(button.theme.rowHeight, 35, 'geometry style reaches controls')
  local colour = false
  for _, call in ipairs(state.fixture:drawCalls 'setColor') do
    if call[2] == 0.1 and call[3] == 0.8 and call[4] == 0.2 then
      colour = true
    end
  end
  expect.truthy(colour, 'the recorder sees custom visual output')
  state.field:focus()
  fixture.press(state, 'run')
  local panel, field, held = state.panel, state.field, state.button
  local selection = state.themes:select(state.owner, { colors = { control = { 0.2, 0.7, 0.8, 1 } } })
  state.fixture:draw()
  expect.equal(state.panel, panel, 'a live palette update retains the panel')
  expect.equal(state.field, field, 'a live palette update retains the focused field')
  expect.equal(state.button, held, 'a live palette update retains the held button')
  expect.equal(#state.activations, 1, 'a live palette update does not activate the held gesture')
  local pressed, focused = false, false
  for _, visual in ipairs(heard) do
    pressed = pressed or (visual.id == 'run' and visual.pressed and visual.theme.control[1] == 0.2)
    focused = focused or (visual.id == 'draft' and visual.focused and visual.theme.control[1] == 0.2)
  end
  expect.truthy(pressed, 'hooks see actual pressed state under the updated palette')
  expect.truthy(focused, 'hooks see routed field focus under the updated palette')
  state.button:setEnabled(false)
  state.fixture:draw()
  expect.equal(#state.activations, 1, 'disable cancels the held gesture under the custom theme')
  selection:dispose()
end)

return test
