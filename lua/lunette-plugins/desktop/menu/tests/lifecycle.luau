local testing = require '@testing'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
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

test('callbacks can dispose the menu safely', function()
  withMenu(function(env)
    env:open()
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

return test
