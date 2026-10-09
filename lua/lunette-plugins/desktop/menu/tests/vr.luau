local testing = require '@testing'
local fixture = require './support/fixture'
local expect = testing.expect
local test = testing.suite()

local function withMenu(provider, config, run)
  local env = fixture.boot(provider, config)
  run(env)
  env.running:close()
end

test('UI opens invokes repeats and closes through release controls', function()
  withMenu('ui', nil, function(env)
    local action = env:register('draft', { label = 'Draft', selected = true })
    expect.equal(env:description().width, 0.115)
    env:press 'open'
    expect.equal(env:description().width, 0.115, 'press does not open')
    env:release()
    expect.equal(env:description().width, 0.32)
    local _, row = env.running:discover(env.ui, 'desktop/menu', 'actions', 'draft')
    expect.truthy(row.label:find('Draft', 1, true))
    expect.truthy(row.label:find('[selected]', 1, true))
    env:click('actions', 'draft')
    env:click('actions', 'draft')
    expect.equal(action.calls(), 2, 'the same row can run repeatedly')
    env:click 'close'
    expect.equal(env:description().width, 0.115)
    env.running:draw()
    expect.truthy(#env.running:drawCalls() > 0)
    expect.equal(#env.ui:panels(), 1, 'one retained panel')
  end)
end)

test('UI updates rows and cancels a removed registration before replacement', function()
  withMenu('ui', nil, function(env)
    local old = env:register 'draft'
    env:open()
    env:press('actions', 'draft')
    env.running:step()
    env.running:step()
    env:release()
    expect.equal(old.calls(), 1, 'unchanged snapshots preserve a held row')
    env:press('actions', 'draft')
    old.effect:dispose()
    local replacement = env:register 'draft'
    env.running:step()
    env:release()
    expect.equal(old.calls(), 1)
    expect.equal(replacement.calls(), 0, 'a replacement never receives the stale gesture')
    env:click('actions', 'draft')
    expect.equal(replacement.calls(), 1)
    env.actions.service:update(replacement.owner, replacement.effect, { enabled = false, selected = true })
    env.running:step()
    local description = env:description()
    local found
    for _, control in description.controls do
      for _, item in control.items do
        if item.id == 'draft' then
          found = item
        end
      end
    end
    expect.equal(found.enabled, false)
    expect.truthy(found.label:find('[selected]', 1, true))
    replacement.instance:disable()
    env.running:step()
    for _, control in env:description().controls do
      expect.equal(#control.items, 0)
    end
  end)
end)

test('UI scrolls late actions and tracking loss cancels held rows', function()
  withMenu('ui', nil, function(env)
    env:open()
    local last
    for index = 1, 24 do
      last = env:register('item-' .. index, { order = index })
    end
    env.running:step()
    expect.raises(function()
      env.running:discover(env.ui, 'desktop/menu', 'actions', 'item-24')
    end, 'no visible')
    for _ = 1, 10 do
      env:scroll(-1)
    end
    env:click('actions', 'item-24')
    expect.equal(last.calls(), 1)
    env:press('actions', 'item-24')
    env.running:tracked(env.hand, false)
    env.running:step()
    expect.equal(env:description().visible, false)
    env.running:tracked(env.hand, true)
    env.running:step()
    env:release()
    expect.equal(last.calls(), 1)
    expect.equal(env:description().width, 0.115, 'reacquisition stays closed')
    env:open()
    env:click 'close'
  end)
end)

test('right wrist preserves configured transform size and pointer haptic', function()
  local offset = vector.pack(0.2, -0.3, 0.4)
  withMenu('ui', { hand = 'right', size = 0.2, offset = offset, haptic = { strength = 0.4 } }, function(env)
    local description = env:description()
    expect.equal(description.width, 0.2)
    expect.equal(description.height, 0.2)
    local expected = lovr.math.newMat4(env.running.native.events.controllers.right.pose)
    expected:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
    for index, value in { expected:unpack(true) } do
      expect.near(description.pose[index], value, 1e-5)
    end
    local current, control = env.running:discover(env.ui, 'desktop/menu', 'open')
    local bounds = control.bounds
    env.running:aim(current, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, env.pointerHand)
    env.running:step()
    local before = env.running.native.events.haptics or 0
    env:press 'open'
    expect.equal(env.running.native.events.haptics, before + 1, 'one UI press pulse after laser hover')
    local pulse = env.running.native.events.haptic
    expect.equal(pulse.strength, 0.4)
    expect.equal(pulse.duration, 0.05)
    expect.equal(pulse.device, 'hand/' .. env.pointerHand)
    env:release()
    expect.equal(env:description().width, 0.32, 'real pointer picks the documented wrist front')
    expect.equal(env.running.native.events.haptics, before + 1, 'release does not duplicate the pulse')
  end)
end)

return test
