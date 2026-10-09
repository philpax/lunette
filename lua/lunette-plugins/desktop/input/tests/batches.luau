local testing = require '@testing'
local physical = require './support/physical'
local expect = testing.expect
local test = physical.suite()

local function changeDuringBinding(f, method, target, consume)
  return f.frame[method](f.frame, f.frameOwner, {
    phase = 'binding',
    run = function()
      expect.truthy(target:focus(), 'the binding changes the focused route')
      return consume
    end,
  })
end

test('a consumed printable binding blocks all physical text until the next batch without moving focus', function()
  for _, destination in ipairs { 'local' } do
    local f = physical.boot(if destination == 'local' then nil else destination)
    local target = if destination == 'local' then f:localTarget 'field' else f.nativeTarget
    expect.truthy(target:focus(), 'the route acquires focus')
    local revision = f.focus:revision()
    local binding = f.frame:onKey(f.frameOwner, {
      phase = 'binding',
      run = function(event)
        return event.key == 'q'
      end,
    })
    f:pair('q', 'q')
    local batch = f.batch
    binding:dispose()
    lovr.textinput('later', 108)
    expect.equal(f.focus:revision(), revision, 'the binding leaves focus unchanged')
    expect.equal(f.batch, batch, 'blocking text does not open another batch')
    expect.equal(f:trace(), '', 'neither the consumed key nor any same-batch text reaches the route')
    f:nextBatch()
    expect.equal(f.batch, batch + 1, 'the next update opens a fresh batch')
    lovr.textinput('q', 113)
    expect.equal(
      f:trace(),
      if destination == 'local'
        then 'field:text:q'
        elseif destination == 'host' then 'native-text:q'
        else 'resolve:q|mods:|key:16:down|key:16:up|mods:',
      'fresh independent text reaches the unchanged route'
    )
    f:close()
  end
end)

test('the lazy key batch snapshots focus before binding-phase local and native focus changes', function()
  for _, destination in ipairs { 'local' } do
    for _, consume in ipairs { true } do
      local f = physical.boot 'host'
      local previous = f:localTarget 'previous'
      local nextTarget = if destination == 'local' then f:localTarget 'next' else f.nativeTarget
      expect.truthy(previous:focus(), 'the original field acquires focus')
      local binding = changeDuringBinding(f, 'onKey', nextTarget, consume)
      f:pair('q', 'q')
      lovr.textinput('stale', 115)
      expect.equal(f:trace(), '', 'neither stale key nor text reaches the replacement route')
      binding:dispose()
      f:nextBatch()
      lovr.textinput('é🙂', 233)
      expect.equal(
        f:trace(),
        if destination == 'local' then 'next:text:é🙂' else 'native-text:é🙂',
        'the next batch accepts independent text'
      )
      f:close()
    end
  end
end)

return test.result
