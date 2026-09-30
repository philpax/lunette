assert(#events.spawned == 1, 'startup opens one demonstration terminal')
assert(events.enumerations == 1, 'adoption enumerates once')
for _, name in ipairs { 'load', 'update', 'draw', 'quit', 'keypressed', 'textinput' } do
  assert(type(lovr[name]) == 'function', name)
end
lovr.load()
assert(#events.spawned == 1 and events.enumerations == 1, 'load is idempotent')
emit('onProcessExited', { process = { id = 999 }, outcome = 'spawnFailed' })
assert(#events.spawned == 1, 'unrelated process does not trigger fallback')
emit('onProcessExited', { process = events.spawned[1], outcome = 'spawnFailed' })
assert(#events.spawned == 2 and events.spawned[2].argv[1] == 'foot', 'missing terminal advances fallback')
events.startupProcesses = #events.spawned
events.windows = { newWindow(1), newWindow(2, 'firefox') }
for _, window in ipairs(events.windows) do
  emit('onWindowOpened', { window = window })
end
lovr.update(0.016)
assert(lovr.draw(events.pass) == false, 'draw does not submit or veto the pass')
assert(#events.seats == 2, 'each hand owns its own seat')
assert(#events.claims == 2, 'one panel claim per live window')
assert(#events.draw > 0)
local lines = 0
for _, call in ipairs(events.draw) do
  if call[1] == 'line' then
    lines += 1
  end
end
assert(lines == 2, 'one beam per hand')
local wrist, beam = 0, 0
for index, call in ipairs(events.draw) do
  if call[1] == 'text' and call[2] == 'kbd' then
    wrist = index
  end
  if call[1] == 'line' and beam == 0 then
    beam = index
  end
end
assert(wrist > 0 and beam > wrist, 'beams draw after wrist surfaces')
assert(events.textures == 2, 'each window texture is fetched for the current frame')
events.trigger = true
lovr.update(0.016)
events.trigger = false
lovr.update(0.016)
local before = #events.input
lovr.textinput('Qq', 0)
lovr.keypressed('backspace', 0, false)
assert(#events.input > before, 'desktop text and named keys reach focused window')
events.held.lctrl = true
before = #events.input
lovr.textinput('q', 0)
assert(#events.input == before, 'modified text is handled only by the chord path')
lovr.keypressed('q', 0, false)
assert(#events.input == before + 4, 'chord holds and clears its modifier around one stroke')
events.held.lctrl = nil
emit('onError', { message = 'fixture report', traceback = 'fixture trace' })
lovr.draw(events.pass)
assert(subscriptionCount 'onWindowOpened' == 1)
assert(subscriptionCount 'onProcessExited' == 1)
assert(subscriptionCount 'onError' == 1)
