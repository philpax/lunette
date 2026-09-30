function lovr.conf(t: LovrConfiguration)
  t.version = '0.19.0'
  t.identity = 'configuration-fixture'
  t.saveprecedence = false

  t.modules.audio = true
  t.modules.data = true
  t.modules.event = true
  t.modules.graphics = true
  t.modules.headset = true
  t.modules.math = true
  t.modules.physics = true
  t.modules.system = true
  t.modules.task = true
  t.modules.thread = true
  t.modules.timer = true

  t.audio.debug = false
  t.audio.samplerate = nil
  t.audio.samplerate = 48000
  t.audio.start = true
  t.audio.reverb.type = 'none'
  t.audio.reverb.type = 'convolution'
  t.audio.reverb.type = 'parametric'
  t.audio.reverb.rays = 4096
  t.audio.reverb.bounces = 16
  t.audio.reverb.duration = 2
  t.audio.reverb.rate = 0.1

  t.graphics.debug = false
  t.graphics.vsync = true
  t.graphics.stencil = false
  t.graphics.antialias = true
  t.graphics.lowpower = false
  t.graphics.hdr = false
  t.graphics.shadercache = true

  t.headset.connect = true
  t.headset.start = true
  t.headset.debug = false
  t.headset.seated = false
  t.headset.mask = true
  t.headset.stencil = false
  t.headset.antialias = true
  t.headset.supersample = false
  t.headset.supersample = 1.5
  t.headset.dynamicresolution = true
  t.headset.submitdepth = true
  t.headset.overlay = true
  t.headset.overlay = 3
  t.headset.controllerskeleton = 'none'
  t.headset.controllerskeleton = 'controller'
  t.headset.controllerskeleton = 'natural'
  t.headset.extensions = { 'XR_EXT_hand_tracking', 'XR_EXTX_overlay' }
  t.headset.extensions = nil

  t.math.globals = true
  t.thread.workers = -1

  t.window.width = 1280
  t.window.height = 800
  t.window.centered = true
  t.window.fullscreen = false
  t.window.resizable = true
  t.window.title = 'Configuration fixture'
  t.window.icon = 'icon.png'
  t.window.icon = nil
end

local function clearOptionalFields(t: LovrConfiguration, image: Image, blob: Blob)
  t.audio.start = nil
  t.audio.reverb = nil
  t.headset.supersample = nil
  t.headset.dynamicresolution = nil
  t.headset.mask = nil
  t.headset.antialias = nil
  t.headset.controllerskeleton = nil
  t.thread.workers = nil
  t.window.width = nil
  t.window.height = nil
  t.window.title = nil
  t.window.icon = image
  t.window.icon = blob
  t.window = nil
end

return clearOptionalFields
