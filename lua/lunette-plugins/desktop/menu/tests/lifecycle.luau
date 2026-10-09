local testing = require '@testing'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local interaction = require '@lunette-contracts/interaction'
local surfaces = require '@lunette-contracts/surfaces'
local fixture = require './support/fixture'
local expect = testing.expect
local test = testing.suite()

local function withMenu(run)
  local env = fixture.boot()
  run(env)
  env.running:close()
end

test('replacement after the scene snapshot cannot receive an armed row release', function()
  withMenu(function(env)
    local old = env:register 'draft'
    env:open()
    env:press('actions', 'draft')
    local replacement
    env.running.session:use(plugin.define {
      name = 'testing/late-replacement',
      requires = { frame = frame.capability },
      init = function(context)
        context:require(frame.capability):onUpdate(context, {
          phase = 'scene',
          order = 2,
          run = function()
            if not replacement then
              old.effect:dispose()
              replacement = env:register 'draft'
            end
          end,
        })
      end,
    })
    env:release()
    expect.equal(old.calls(), 0)
    expect.equal(replacement.calls(), 0, 'retained descriptor token rejects the replacement')
    env:click('actions', 'draft')
    expect.equal(replacement.calls(), 1)
  end)
end)

test('failed actions report once and callbacks can dispose the menu safely', function()
  withMenu(function(env)
    env:register('fail', {
      run = function()
        error 'action refused'
      end,
    })
    env:open()
    env:click('actions', 'fail')
    local reports = env.running.native.events.reported
    expect.equal(#reports, 1, 'the broker reports the failed result once')
    expect.truthy(reports[1].message:find('action refused', 1, true))
    testing.takeReports()
    env:register('stop', {
      run = function()
        env.running.session.instances['desktop/menu']:disable()
      end,
    })
    env.running:step()
    local panel = env.ui:panels()[1]
    env:click('actions', 'stop')
    expect.equal(panel.dead, true)
    expect.equal(#env.ui:panels(), 0)
    env.running:step()
    env.running:draw()
    env.running.session.instances['desktop/menu']:enable()
    env.running:step()
    expect.equal(#env.ui:panels(), 1)
    expect.equal(env:description().width, 0.115)
  end)
end)

test('close cancels a row held by a second independent real pointer', function()
  withMenu(function(env)
    local action = env:register 'draft'
    env:open()
    local observed = env.running.session:observe(interaction.capability)
    local available = env.running.session:observe(surfaces.capability).service
    local held = observed.service:newPointer(observed.context)
    local closer = observed.service:newPointer(observed.context)
    local function drive(pointer, id, item, buttons)
      local description, control =
        env.running:discover(env.ui, if id == 'close' then 'desktop/menu/titlebar' else 'desktop/menu', id, item)
      local bounds = control.bounds
      local pose = lovr.math.newMat4(table.unpack(description.pose))
      pose:translate(
        ((bounds.x + bounds.width / 2) / description.logicalWidth - 0.5) * description.width,
        (0.5 - (bounds.y + bounds.height / 2) / description.logicalHeight) * description.height,
        1
      )
      pointer:update({
        origin = vector.pack(pose:getPosition()),
        direction = vector.pack(pose:mul(0, 0, -1, 0)),
        pose = pose,
        buttons = buttons or {},
        grip = false,
        dt = 0.016,
      }, available:all())
    end
    drive(held, 'actions', 'draft', { left = true })
    drive(closer, 'close', nil, { left = true })
    drive(closer, 'close')
    expect.equal(env:description().width, 0.115)
    held:update({
      origin = vector.pack(0, 0, 0),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4(),
      buttons = {},
      grip = false,
      dt = 0.016,
    }, available:all())
    expect.equal(action.calls(), 0)
  end)
end)

test('secondary real pointer events never open or pulse the UI button', function()
  withMenu(function(env)
    local observed = env.running.session:observe(interaction.capability)
    local available = env.running.session:observe(surfaces.capability).service
    local pulses = 0
    local pointer = observed.service:newPointer(observed.context, {
      vibrate = function()
        pulses += 1
        return true
      end,
    })
    local pose = lovr.math.newMat4(table.unpack(env:description().pose))
    local function drive(buttons)
      pointer:update({
        origin = vector.pack(pose:mul(0, 0, 1, 1)),
        direction = vector.pack(pose:mul(0, 0, -1, 0)),
        pose = pose,
        buttons = buttons or {},
        grip = false,
        dt = 0.016,
      }, available:all())
    end
    drive { right = true }
    drive()
    expect.equal(env:description().width, 0.115)
    expect.equal(pulses, 0)
    drive { left = true }
    expect.equal(env:description().width, 0.115)
    expect.equal(pulses, 1)
    drive()
    expect.equal(env:description().width, 0.32)
    expect.equal(pulses, 1)
  end)
end)

return test
