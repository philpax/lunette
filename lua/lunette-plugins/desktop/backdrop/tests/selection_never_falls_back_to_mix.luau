local testing = require '@testing'
local selection = require '../selection'
local expect = testing.expect
local test = testing.suite()

test('selection_never_falls_back_to_mix', function()
  local native = testing.native()
  local pinned = native.newProcess(31)
  local impostor = { id = 31, dead = false }
  local choice = selection.new()
  expect.equal(choice:source().kind, 'system', 'the default is the system mix')
  choice:pin(pinned)
  for _, state in
    {
      { kind = 'starting' },
      { kind = 'idle' },
      { kind = 'ended' },
      { kind = 'unavailable', reason = 'unresolved-attribution', detail = 'No matching stream' },
      { kind = 'active', provenance = 'application-metadata' },
    }
  do
    choice.audioState = state
    for _, available in { false, true } do
      choice.audioAvailable = available
      expect.equal(choice:source().kind, 'process', 'every provider state preserves process mode')
      expect.equal(choice:source().process, pinned, 'every provider state preserves the exact handle')
    end
  end
  pinned.dead = true
  expect.equal(choice:source().process, pinned, 'a dead selected handle is retained')
  expect.equal(choice:pin(pinned), false, 'a stale row cannot repin a dead process')
  expect.equal(choice.pinned == impostor, false, 'equal numeric ids do not substitute a handle')
  choice:setMode 'attention'
  expect.equal(choice:source(), nil, 'attention without a target never opens the mix')
  choice:setMode 'application'
  expect.equal(choice:source().process, pinned, 'returning to application mode retains the pinned handle')
  choice:setReactive(false)
  expect.equal(choice:source(), nil, 'reactivity off opens no source')
end)

test('configured values override retained choices only when they change', function()
  local choice = selection.new { sourceMode = 'system', reactive = true, response = 0.7, motion = 0.35 }
  choice:setMode 'attention'
  choice:setResponse(0.25)
  choice:setMotion(0.75)
  choice:configure { sourceMode = 'system', reactive = true, response = 0.7, motion = 0.35 }
  expect.equal(choice.mode, 'attention', 'equal configuration preserves the runtime mode')
  expect.equal(choice.response, 0.25, 'equal configuration preserves runtime response')
  expect.equal(choice.motion, 0.75, 'equal configuration preserves runtime motion')
  choice:configure { sourceMode = 'application', reactive = true, response = 0.8, motion = 0.35 }
  expect.equal(choice.mode, 'application', 'changed configured mode overrides runtime mode')
  expect.equal(choice.response, 0.8, 'changed configured response overrides runtime response')
  expect.equal(choice.motion, 0.75, 'unrelated changes preserve runtime motion')
  expect.equal(selection.new().mode, 'system', 'a new factory starts with default choices')
end)

test('retained dead selections report ended unless audio explicitly observes a starting process', function()
  local process = { id = 300, dead = false }
  local choice = selection.new()
  choice:pin(process)
  process.dead = true
  expect.equal(choice:status(), 'Application #300: ended', 'a retained dead handle without audio is visibly ended')
  choice.audioAvailable = true
  expect.equal(choice:status(), 'Application #300: ended', 'no observation does not invent a starting state')
  choice.audioState = { kind = 'starting' }
  expect.equal(
    choice:status(),
    'Application #300: starting',
    'an explicit starting observation describes a pending process'
  )
  choice.audioState = { kind = 'active', provenance = 'application-metadata' }
  expect.equal(choice:status(), 'Application #300: ended', 'a stale active observation does not hide a dead selection')
  choice.audioState = { kind = 'ended' }
  expect.equal(choice:status(), 'Application #300: ended', 'an ended observation remains explicit')
  choice.audioState = nil
  choice:setMode 'attention'
  choice.attended = process
  expect.equal(choice:status(), 'Application #300: ended', 'retained attention handles report the same ended state')
end)

return test
