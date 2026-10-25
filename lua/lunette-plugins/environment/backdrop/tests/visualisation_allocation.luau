local testing = require '@testing'
local kinds = require '../private/visualisation/kinds'
local scene = require '../private/visualisation/scene'
local uiHost = require '@lunette-contracts/ui-host'
local expect = testing.expect
local test = testing.suite()

type VolumeDraw = (Pass, uiHost.Volume) -> ()

local function ignore(...: unknown): () end

test('warm visual reruns keep geometry storage across nodes and registration lifetimes', function()
  local native = testing.native()
  local visuals: { [string]: uiHost.Visual } = {}
  local effects: { () -> () } = {}
  local callbacks: { VolumeDraw } = {}
  local host = {
    registerKind = ignore,
    registerVisual = function(_: unknown, _: unknown, name: string, visual: uiHost.Visual): ()
      visuals[name] = visual
    end,
  }
  local owner = {
    effect = function(_: unknown, acquire: () -> () -> ()): ()
      effects[#effects + 1] = acquire()
    end,
  }
  local rows: { scene.Row } = {}
  for index = 1, 24 do
    rows[index] = { spectrum = table.create(8, 0.5), stereo = table.create(8, 0.2) }
  end
  local sources: kinds.Sources = {
    history = rows,
    observed = { raw = table.create(8, 1), frame = { waves = {} } :: any, facing = 0.5, anchor = 0.25 },
    palette = { bass = { 0.2, 0.3, 0.4 }, mid = { 0.4, 0.5, 0.6 }, treble = { 0.6, 0.7, 0.8 } },
    miniature = ignore,
    sectors = 12,
    hold = 0.65,
  }
  local theme = { colors = { sunken = {}, accent = { 0.2, 0.4, 0.6, 1 } }, radii = { control = 0.01 } }
  local first = { theme = theme, props = { size = 0.2 } }
  local second = { theme = theme, props = { size = 0.3 } }
  local volume = { width = 0.8, height = 0.2, depth = 0.05, opacity = 1, scrim = 0, pose = lovr.math.newMat4() }
  local draw = {
    box = ignore,
    volume = function(_: unknown, _: unknown, spec: uiHost.VolumeSpec): ()
      callbacks[#callbacks + 1] = spec.draw
    end,
  }
  local pass = {
    setShader = ignore,
    setDepthTest = ignore,
    setDepthWrite = ignore,
    setColor = ignore,
    box = ignore,
    translate = ignore,
    rotate = ignore,
    cylinder = ignore,
    capsule = ignore,
    sphere = ignore,
  }
  local partialHost = host :: any
  local partialOwner = owner :: any
  kinds.register(partialHost, partialOwner, sources)
  local function render(): ()
    table.clear(callbacks)
    visuals['desktop/backdrop/skyline'](first :: any, draw :: any)
    visuals['desktop/backdrop/skyline'](second :: any, draw :: any)
    visuals['desktop/backdrop/model'](first :: any, draw :: any)
    visuals['desktop/backdrop/model'](second :: any, draw :: any)
    for _, callback in callbacks do
      callback(pass :: any, volume)
    end
  end
  for _ = 1, 3 do
    kinds.register(partialHost, partialOwner, sources)
    render()
    render()
    collectgarbage 'collect'
    collectgarbage 'stop'
    local before = collectgarbage 'count'
    local ok, problem = pcall(function(): ()
      for _ = 1, 30 do
        render()
      end
    end)
    local growth = collectgarbage 'count' - before
    collectgarbage 'restart'
    assert(ok, problem)
    expect.truthy(growth < 128, 'warm visual reruns allocate less than 128 KiB with collection stopped')
    expect.equal(#effects, 1, 'the registration acquires one shader')
    effects[1]()
    table.clear(effects)
  end
  expect.equal(#native.events.reported, 0, 'the independent registrations close cleanly')
end)

return test
