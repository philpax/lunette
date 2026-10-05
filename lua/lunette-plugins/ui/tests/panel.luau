local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/panel'
local suite = testing.suite()
local function test(name, run)
  suite(name, function()
    local ok, failure = pcall(run)
    fixture.closeAll()
    if not ok then
      error(failure, 0)
    end
  end)
end

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
  state.fixture:close()
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
  state.fixture:close()
end)

test('the VR UI fixture discovers a dynamic control and rediscovers the provider after reload', function()
  local state = fixture.boot()
  local first = state.panel:describe()
  local function late(x)
    return state.panel:button(state.owner, {
      id = 'late',
      label = 'Late',
      bounds = { x = x, y = 55, width = 25, height = 10 },
      onActivate = function()
        state.late = (state.late or 0) + 1
      end,
    })
  end
  local old = late(10)
  click(state, 'late')
  expect.equal(state.late, 1, 'new public geometry drives the actual pointer')
  old:destroy()
  late(350)
  click(state, 'late')
  expect.equal(state.late, 2, 'changed control geometry is rediscovered')
  local provider = state.fixture.session.instances.ui
  provider:reload {}
  expect.truthy(old.dead, 'retained control is dead')
  local nextDescription = state.panel:describe()
  expect.truthy(first.generation ~= nextDescription.generation, 'provider replacement changes generation identity')
  expect.equal(#state.service:panels(), 1, 'replacement contains only live panels')
  click(state, 'run')
  expect.equal(#state.activations, 1, 'replacement geometry receives a fresh gesture')
  state.fixture:close()
end)

test('panel descriptions are detached and control geometry is half open', function()
  local state = fixture.boot()
  local old = state.panel:describe()
  expect.raises(function()
    old.controls[1].bounds.x = 900
  end, 'readonly', 'descriptions cannot mutate geometry')
  state.button:setBounds { x = 10, y = 10, width = 0, height = 40 }
  local nextDescription = state.panel:describe()
  expect.truthy(nextDescription.revision > old.revision, 'explicit geometry changes revision')
  expect.equal(old.controls[1].bounds.width, 80, 'retained descriptions do not mutate')
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
  state.fixture:close()
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
  state.fixture:close()
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
  state.fixture:close()
end)

return suite
