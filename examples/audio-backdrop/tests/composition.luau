local testing = require '@testing'
local desktop = require '@lunette-desktop'
local expect = testing.expect
local test = testing.suite()

test('the example adds an independent meter to the complete default desktop', function()
  local native = testing.native()
  testing.host.useConfiguration 'examples/audio-backdrop'
  require 'main'
  lovr.load()
  native.advanceFrame()
  lovr.update(0.016)
  local meter, backdrop, audio, analysis = false, false, false, false
  for _, entry in desktop.compose() do
    backdrop = backdrop or entry.id == 'desktop/backdrop'
    audio = audio or entry.id == 'audio'
    analysis = analysis or entry.id == 'audio-analysis'
  end
  lovr.draw(native.events.pass)
  for _, call in native.events.draw do
    meter = meter or (call[1] == 'text' and call[2]:find('Audio meter:', 1, true) ~= nil)
  end
  expect.truthy(backdrop, 'the complete desktop includes the backdrop')
  expect.truthy(audio and analysis, 'the providers are independent desktop entries')
  expect.truthy(meter, 'the example consumer runs alongside the desktop')
  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(native.events.audioOpened, native.events.audioClosed, 'quit releases all audio readers')
end)

return test
