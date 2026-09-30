function lovr.conf(t: LovrConfiguration)
  t.identitiy = 'configuration-fixture' -- reject.
  t.modules.tasks = true -- reject.
  t.modules.task = 'yes' -- reject.
  t.audio.samplerate = false -- reject.
  t.audio.reverb.rays = nil -- reject.
  t.audio.reverb.type = 'room' -- reject.
  t.graphics.lowpower = 1 -- reject.
  t.graphics.vsync = 'on' -- reject.
  t.headset.dynamicResolution = true -- reject.
  t.headset.controllerskeleton = 'hands' -- reject.
  t.headset.supersample = '2' -- reject.
  t.headset.overlay = 'front' -- reject.
  t.headset.extensions = { false } -- reject.
  t.math.globals = 1 -- reject.
  t.thread.workers = 'auto' -- reject.
  t.window.width = '1280' -- reject.
  t.window.icon = 3 -- reject.
  t.window = false -- reject.
end
