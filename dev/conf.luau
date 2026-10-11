-- Development state is separate from the shipped desktop's saved arrangement.
function lovr.conf(t: LovrConfiguration)
  t.identity = 'lunette-dev'
  t.saveprecedence = false
  t.headset.backend = 'auto'
  t.headset.overlay = true
  t.window.title = 'lunette development'
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
end
