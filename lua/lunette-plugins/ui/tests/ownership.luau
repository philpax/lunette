local testing = require '@testing'
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local focus = require '@lunette-contracts/focus'
local vrUi = require '@testing/vr-ui'
local handles = require '@lunette-plugins/ui/control-handle'
local ownership = require './support/ownership'
local expect = testing.expect
local suite = testing.suite()

local function test(name, run)
  suite(name, function()
    local running = vrUi.boot {
      'theme',
      'frame',
      'surfaces',
      'drops',
      'focus',
      'interaction',
      'laser',
      'keyboard',
      'desktop/pointing',
      'ui',
    }
    run(running)
    running:close()
  end)
end

local function consumer(running, name, init)
  local state = {}
  state.instance = running.session:use(plugin.define {
    name = name,
    requires = { ui = ui.capability },
    init = function(context)
      state.owner = context
      state.service = context:require(ui.capability)
      if init then
        init(state)
      end
    end,
  })
  expect.equal(state.instance:state(), 'active', tostring(state.instance:diagnostic()))
  return state
end

local function panel(state, name)
  return state.service:newPanel(state.owner, {
    name = name,
    pose = lovr.math.newMat4():translate(0, 1.5, -2),
    width = 2,
    height = 1,
    logicalWidth = 200,
    logicalHeight = 100,
  })
end

local function button(current, owner, id)
  return current:button(owner, {
    id = id,
    bounds = { x = 10, y = 10, width = 30, height = 30 },
    onActivate = function() end,
  })
end

test('a control id belongs to its owner across every panel', function(running)
  local state = consumer(running, 'testing/ui-owner')
  local first, second = panel(state, 'first'), panel(state, 'second')
  local original = button(first, state.owner, 'shared')
  expect.raises(function()
    button(second, state.owner, 'shared')
  end, 'duplicate', 'same-owner ids are provider-wide')
  expect.truthy(original:destroy(), 'the original is released')
  expect.falsy(original:destroy(), 'release is idempotent')
  local replacement = button(second, state.owner, 'shared')
  expect.falsy(replacement.dead, 'release frees the reservation')
end)

test('different owners can use the same id in one panel without exposing contexts', function(running)
  local first = consumer(running, 'testing/ui-first-owner')
  local second = consumer(running, 'testing/ui-second-owner')
  local current = panel(first, 'shared-panel')
  local activations = {}
  local function shared(owner, x, name)
    return current:button(owner, {
      id = 'shared',
      bounds = { x = x, y = 10, width = 30, height = 30 },
      onActivate = function()
        activations[#activations + 1] = name
      end,
    })
  end
  local a, b = shared(first.owner, 10, 'first'), shared(second.owner, 80, 'second')
  expect.truthy(a.owner ~= b.owner, 'owner identities are distinct')
  expect.truthy(a.owner ~= first.owner and b.owner ~= second.owner, 'identities do not expose contexts')
  expect.equal(a.owner.kind, 'ui-owner', 'the token is neutral')
  expect.truthy(table.isfrozen(a.owner), 'the identity is immutable')
  local described = current:describe().controls
  expect.equal(described[1].owner, a.owner, 'inspection preserves the first identity')
  expect.equal(described[2].owner, b.owner, 'inspection preserves the second identity')
  expect.raises(function()
    running:discover(first.service, 'shared-panel', 'shared')
  end, 'ambiguous', 'id-only selection rejects ambiguity')
  running:clickControl(first.service, 'shared-panel', 'shared', nil, nil, a.owner)
  running:clickControl(first.service, 'shared-panel', 'shared', nil, nil, b.owner)
  expect.equal(table.concat(activations, ','), 'first,second', 'token-selected VR clicks reach the actual owner')
end)

test('owner identities stay stable across panels and renew after owner or provider replacement', function(running)
  local state = consumer(running, 'testing/ui-renewed-owner', function(current)
    current.first = panel(current, 'renewed-first')
    current.second = panel(current, 'renewed-second')
    current.a = button(current.first, current.owner, 'first')
    current.b = button(current.second, current.owner, 'second')
  end)
  local original = state.a
  expect.equal(original.owner, state.b.owner, 'one activation has one identity')
  state.instance:reload {}
  expect.truthy(original.dead, 'owner replacement ends retained controls')
  expect.truthy(state.a.owner ~= original.owner, 'owner replacement renews identity')
  local before = state.a
  running.session.instances.ui:reload {}
  expect.truthy(before.dead, 'provider replacement ends retained controls')
  expect.truthy(state.a.owner ~= before.owner, 'provider replacement renews identity')
end)

test('destroying a shared panel frees another live owners ids and focus targets', function(running)
  local first = consumer(running, 'testing/ui-panel-owner')
  local second = consumer(running, 'testing/ui-control-owner')
  local current = panel(first, 'destroyed-panel')
  local field = current:textField(second.owner, {
    id = 'field',
    bounds = { x = 10, y = 10, width = 60, height = 30 },
  })
  expect.truthy(field:focus(), 'a UI-only caller obtains local focus')
  expect.truthy(current:destroy(), 'panel disposal succeeds')
  expect.truthy(field.dead, 'shared control is disposed')
  expect.falsy(field:destroy(), 'the owner effect is already disarmed')
  local nextPanel = panel(second, 'next-panel')
  expect.falsy(button(nextPanel, second.owner, 'field').dead, 'panel disposal releases the provider-wide reservation')
end)

for _, operation in { 'key', 'text' } do
  test('a raw receiver ' .. operation .. ' failure is labeled once and remains a failed focus result', function(running)
    local state = consumer(running, 'testing/ui-raw-owner')
    local source
    running.session:use(plugin.define {
      name = 'testing/ui-focus-source',
      requires = { focus = focus.capability },
      init = function(context)
        source = context:require(focus.capability):newSource(context)
      end,
    })
    local current = panel(state, 'raw-panel')
    current:region(state.owner, {
      id = 'raw',
      bounds = { x = 10, y = 10, width = 30, height = 30 },
      receiver = {
        key = function()
          error 'raw key failure'
        end,
        text = function()
          error 'raw text failure'
        end,
      },
    })
    running:clickControl(state.service, 'raw-panel', 'raw')
    local result = if operation == 'key' then source:key { code = 30 } else source:text 'a'
    expect.equal(result.kind, 'failed', 'receiver failure is not unhandled')
    local reports = running.native.events.reported
    expect.equal(#reports, 1, 'the focus boundary alone reports the failure')
    local message = reports[1].message
    expect.truthy(string.find(message, 'testing/ui-raw-owner', 1, true), 'the actual caller owner is labeled')
    expect.truthy(string.find(message, 'raw', 1, true), 'the control id is labeled')
    expect.truthy(string.find(message, 'raw ' .. operation .. ' failure', 1, true), 'the original error survives')
  end)
end

test('factory reentrancy reserves ids before callbacks and factory failures release them', function(running)
  local state = ownership.panel(running)
  local create
  create = function(factory)
    return handles.create(state, state.owner, ownership.options 'reserved', factory or ownership.widget)
  end
  local original = create(function(host)
    expect.raises(function()
      create()
    end, 'duplicate', 'a reentrant factory cannot steal the id')
    return ownership.widget(host)
  end)
  local identity = original.owner
  original:destroy()
  expect.raises(function()
    create(function()
      error 'factory failure'
    end)
  end, 'factory failure', 'factory errors escape')
  local replacement = create()
  expect.equal(replacement.owner, identity, 'empty owner registries retain activation identity')
  expect.equal(#state.controls, 1, 'failed factories leave no control record')
end)

test('failed focus registration and interrupted acquisition leave no reserved controls', function(running)
  local failingFocus = {
    register = function()
      error 'focus acquisition failure'
    end,
  }
  local state = ownership.panel(running, nil, failingFocus)
  local receiver = {
    key = function()
      return false
    end,
    text = function()
      return false
    end,
  }
  expect.raises(function()
    handles.create(state, state.owner, ownership.options 'failed', function(host)
      return ownership.widget(host, receiver)
    end)
  end, 'focus acquisition failure', 'failed focus registration escapes')
  expect.equal(#state.controls, 0, 'failed registration leaves no record')
  expect.falsy(
    handles.create(state, state.owner, ownership.options 'failed', ownership.widget).dead,
    'registration failure frees the id'
  )

  local destroyed = 0
  local interrupted, instance
  local target = {
    dead = false,
    destroy = function(self)
      self.dead = true
      destroyed += 1
      return true
    end,
  }
  interrupted, instance = ownership.panel(running, nil, {
    register = function()
      instance:disable()
      return target
    end,
  })
  expect.raises(function()
    handles.create(interrupted, interrupted.owner, ownership.options 'interrupted', function(host)
      return ownership.widget(host, receiver)
    end)
  end, 'ended', 'owner death during registration prevents publication')
  expect.equal(destroyed, 1, 'partial target is released')
  expect.equal(#interrupted.controls, 0, 'interrupted acquisition leaves no control')
  expect.equal(next(interrupted.owners), nil, 'owner teardown removes every reservation')
end)

test('host lifetime guards suppress normal callbacks after disposal and owner death', function(running)
  local state, instance = ownership.panel(running)
  local host
  local current = handles.create(state, state.owner, ownership.options 'guarded', function(created)
    host = created
    return ownership.widget(created)
  end)
  local called = 0
  local function callback()
    called += 1
  end
  expect.truthy(host.interactive(), 'new enabled control is interactive')
  current:setEnabled(false)
  expect.truthy(host.live(), 'disabled control retains its lifetime')
  expect.falsy(host.interactive(), 'disabled control cannot interact')
  current:destroy()
  expect.falsy(host.callback('normal', callback), 'normal callbacks stop after disposal')
  expect.truthy(host.callback('terminal', callback, true), 'explicit terminal cleanup can notify a live owner')
  instance:disable()
  expect.falsy(host.callback('terminal', callback, true), 'terminal cleanup never calls a dead owner')
  expect.equal(called, 1, 'only deliberate live-owner cleanup runs')
end)

return suite
