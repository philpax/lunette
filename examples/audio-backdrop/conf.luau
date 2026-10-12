-- Example state is separate from the shipped desktop's saved arrangement.
function lovr.conf(t: LovrConfiguration)
  t.identity = 'lunette-example-audio-backdrop'
  t.saveprecedence = false
  t.headset.backend = 'auto'
  t.headset.overlay = true
  t.window.title = 'lunette audio backdrop example'
end
