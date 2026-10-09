local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/display'
local test = testing.suite()

test('display listeners require a declared live owner and a plain callback table', function()
  local env = fixture.start()
  local service, owner = env.display.service, env.display.context
  expect.raises(function()
    service:onChanged({}, { run = function() end })
  end, 'owner')
  for _, listener in { false, 'listener', function() end, setmetatable({}, {}) } do
    expect.raises(function()
      service:onChanged(owner, listener)
    end, 'keyboard%-display onChanged: listener is a plain table')
  end
  expect.raises(function()
    service:onChanged(owner, { run = true })
  end, 'run is a plain callback')
  expect.raises(function()
    service:onChanged(owner, { run = function() end, extra = true })
  end, 'unknown')
  expect.raises(function()
    env.rawDisplay.show = env.rawDisplay.hide
  end, 'readonly')
  env.session:close()
end)

test('an observer can unload the display during show without skipping board destruction', function()
  local env = fixture.start()
  local raw = env.rawDisplay
  local run = raw.show
  raw:onChanged(env.display.context, {
    run = function(change)
      if change.reason == 'show' then
        env.session.instances['desktop/keyboard']:disable()
      end
    end,
  })
  expect.falsy(run(raw), 'show reports that its activation ended')
  expect.equal(fixture.boardCount(env), 0)
  expect.falsy(run(raw), 'a cached method is inert after teardown')
  env.session:close()
end)

test('keyboard acquisition reentry creates one board and preserves the newest hidden intent', function()
  local plugin = require '@lunette-plugin'
  local contract = require '@lunette-contracts/keyboard'
  local keyboard = require '@lunette-plugins/keyboard'
  local env, creations = nil, 0
  local provider = plugin.define {
    name = 'testing/acquisition-keyboard',
    requires = keyboard.requires,
    provides = { keyboard = contract.capability },
    init = function(context, _config, publish)
      local real = keyboard.build(context)
      publish:provide(contract.capability, {
        inspect = function(_self)
          return real:inspect()
        end,
        new = function(_self, owner, options)
          creations += 1
          expect.falsy(env.rawDisplay:show(), 'recursive acquisition cannot create a second board')
          expect.truthy(env.rawDisplay:hide(), 'the newest intent is hidden')
          return real:new(owner, options)
        end,
      })
    end,
  }
  env = fixture.start { keyboard = { id = 'keyboard', definition = provider } }
  expect.falsy(env.rawDisplay:show(), 'an older show cannot replace a newer hide')
  expect.equal(creations, 1)
  expect.equal(fixture.boardCount(env), 1, 'the single board is retained hidden')
  expect.falsy(env.rawDisplay:isVisible())
  expect.equal(fixture.shown(env), nil)
  env.session:close()
end)

return test
