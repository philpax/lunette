function lovr.conf(t: LovrConfiguration)
  t.identitiy = 'configuration-fixture' -- reject.
  t.modules.tasks = true -- reject.
  t.audio.samplerate = false -- reject.
  t.audio.reverb.type = 'room' -- reject.
  t.headset.extensions = { false } -- reject.
  t.window = false -- reject.
end
