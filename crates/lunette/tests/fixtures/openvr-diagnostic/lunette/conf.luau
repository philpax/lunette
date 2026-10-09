function lovr.conf(t)
  t.identity = 'lunette-openvr-manual-diagnostic'
  t.saveprecedence = false
  t.modules.audio = false
  t.modules.task = false
  t.headset.backend = 'openvr'
  t.headset.overlay = true
  t.window = nil
end
