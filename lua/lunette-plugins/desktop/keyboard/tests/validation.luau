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
  for _, listener in { false, 'listener', function() end } do
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

return test
