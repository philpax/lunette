-- Lifecycle checks run without a display, XR runtime, or audio device.

function lovr.conf(t: LovrConfiguration)
  t.identity = 'lunette-gc-lifecycle'
  t.window = nil
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.headset = false
end
