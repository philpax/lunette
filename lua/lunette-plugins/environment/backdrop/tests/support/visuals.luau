-- Captures backdrop visual registrations without recording the rest of a control panel.
local kinds = require '../../private/visualisation/kinds'
local model = require '../../private/rendering/model'
local scene = require '../../private/visualisation/scene'
local oracle = require './scene-oracle'
local uiHost = require '@lunette-contracts/ui-host'

local fixture = {}

type TestObserved = { raw: { number }, frame: { waves: { model.Wave } }, facing: number?, anchor: number? }
type TestSources = {
  history: { scene.Row },
  observed: TestObserved,
  palette: scene.Palette,
  sectors: number,
  hold: number,
  miniature: (unknown, model.Frame, number, number?, number) -> (),
}
type TestNode = {
  theme: { colors: { sunken: { number }, accent: { number } }, radii: { control: number } },
  props: { size: number },
}
type TestPass = { [string]: (...unknown) -> () }
type TestVolume = { width: number, height: number, depth: number, opacity: number, scrim: number, pose: Mat4 }
type VolumeDraw = (Pass, uiHost.Volume) -> ()
type Event = { [any]: unknown }
type Environment = {
  sources: TestSources,
  miniature: { frame: model.Frame?, radius: number?, facing: number?, opacity: number? },
  volume: TestVolume,
  pass: TestPass,
  events: { Event },
  node: () -> TestNode,
  visual: (string, TestNode) -> VolumeDraw,
  skylineExpected: () -> { Event },
  close: () -> (),
}

function fixture.new(): Environment
  local visuals: { [string]: uiHost.Visual } = {}
  local effects: { () -> () } = {}
  local owner = {
    effect = function(_: unknown, acquire: () -> () -> ()): ()
      local release = acquire()
      table.insert(effects, release)
    end,
  }
  local host = {
    registerKind = function(_: unknown, _: unknown, kind: { name: string }): string
      return kind.name
    end,
    registerVisual = function(_: unknown, _: unknown, name: string, visual: uiHost.Visual): ()
      visuals[name] = visual
    end,
  }
  local miniature: { frame: model.Frame?, radius: number?, facing: number?, opacity: number? } = {}
  local sources: TestSources = {
    history = { { spectrum = table.create(8, 0.5), stereo = table.create(8, 0) } },
    observed = { raw = { 0.7 }, frame = { waves = {} }, facing = 0.5, anchor = 0.25 },
    palette = { bass = { 0.1, 0.2, 0.3 }, mid = { 0.4, 0.5, 0.6 }, treble = { 0.7, 0.8, 0.9 } },
    sectors = 12,
    hold = 0.65,
    miniature = function(_: unknown, frame: model.Frame, radius: number, facing: number?, opacity: number): ()
      miniature.frame, miniature.radius, miniature.facing, miniature.opacity = frame, radius, facing, opacity
    end,
  }
  kinds.register(host, owner, sources :: any)
  local volume: TestVolume = {
    width = 0.8,
    height = 0.2,
    depth = 0.05,
    opacity = 0.6,
    scrim = 0.25,
    pose = lovr.math.newMat4(),
  }
  local callbacks: { VolumeDraw } = {}
  local draw = {
    box = function(_: unknown, _: unknown, _: unknown): () end,
    volume = function(_: unknown, _: unknown, spec: uiHost.VolumeSpec): ()
      callbacks[#callbacks + 1] = spec.draw
    end,
  }
  local events: { Event } = {}
  local color: { number } = {}
  local pass: TestPass = {
    setShader = function(...: unknown): () end,
    setDepthTest = function(...: unknown): () end,
    setDepthWrite = function(...: unknown): () end,
    translate = function(_: unknown, ...: unknown): ()
      events[#events + 1] = { 'translate', ... }
    end,
    rotate = function(_: unknown, ...: unknown): ()
      events[#events + 1] = { 'rotate', ... }
    end,
    setColor = function(_: unknown, ...: number): ()
      color = { ... }
    end,
  }
  for _, method in { 'box', 'cylinder', 'capsule', 'sphere' } do
    pass[method] = function(_: unknown, ...: unknown): ()
      events[#events + 1] = { method = method, color = color, values = { ... } }
    end
  end
  return {
    sources = sources,
    miniature = miniature,
    volume = volume,
    pass = pass,
    events = events,
    node = function(): TestNode
      return {
        theme = { colors = { sunken = {}, accent = { 0.3, 0.4, 0.5, 0.8 } }, radii = { control = 0.01 } },
        props = { size = 0.2 },
      }
    end,
    visual = function(kind: string, node: TestNode): VolumeDraw
      table.clear(callbacks)
      local visual = visuals['desktop/backdrop/' .. kind]
      visual(node :: any, draw :: any)
      return callbacks[1]
    end,
    skylineExpected = function(): { Event }
      local shape = oracle.skyline(
        sources.history,
        sources.observed.raw,
        sources.palette,
        volume.width * 0.94,
        volume.height * 0.9,
        volume.depth
      )
      local expected: { Event } = {}
      local function box(bar: scene.Bar): ()
        expected[#expected + 1] = {
          method = 'box',
          color = {
            bar.color[1] * (1 - volume.scrim),
            bar.color[2] * (1 - volume.scrim),
            bar.color[3] * (1 - volume.scrim),
            bar.color[4] * volume.opacity,
          },
          values = { bar.x, bar.y, bar.z, bar.width, bar.height, bar.depth },
        }
      end
      for index = #shape.bars, 1, -1 do
        box(shape.bars[index])
      end
      for _, cap in shape.caps do
        box(cap)
      end
      return expected
    end,
    close = function(): ()
      for index = #effects, 1, -1 do
        effects[index]()
      end
    end,
  }
end

return fixture
