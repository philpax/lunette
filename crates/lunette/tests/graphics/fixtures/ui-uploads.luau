-- Compares renderer uploads with independent table sends through the same shaders and real native glyph atlas.

local testing = require '@testing'
local lunette = require '@lunette'
local renderer = require '@lunette-plugins/ui/host/private/rendering/renderer'
local test = testing.suite()

type Keep = <T>(value: T) -> T
type Defer = (release: () -> ()) -> ()
type Packed = {
  boxes: { number },
  count: number,
  glyphs: { [number]: { number } },
  glyphCounts: { [number]: number },
  images: { any },
  volumes: { any },
}
type Panel = { width: number, height: number, curve: number, pose: Mat4 }
type Step = {
  boxes: number,
  glyphs: number,
  phase: number,
  panel: Panel,
  beginFrame: boolean?,
  endFrame: boolean?,
  blocked: boolean?,
}

local WIDTH, HEIGHT = 384, 256
local BACKGROUND = { 0.02, 0.03, 0.04, 1 }
local THEME = { colors = { edgeLight = { 0.9, 0.8, 0.6, 0.8 }, edgeDark = { 0.1, 0.05, 0.2, 0.7 } } }

local function scope(run: (keep: Keep, defer: Defer) -> ()): ()
  local cleanup = {}
  local function defer(release: () -> ()): ()
    table.insert(cleanup, release)
  end
  local function keep<T>(value: T): T
    defer(function()
      value:release()
    end)
    return value
  end
  local ok, failure = pcall(run, keep, defer)
  for index = #cleanup, 1, -1 do
    cleanup[index]()
  end
  if not ok then
    error(failure, 0)
  end
end

local function acquire(defer: Defer): renderer.Resources
  local resources, release = renderer.acquire(function(message: string): ()
    error(message, 0)
  end)
  defer(release)
  return resources
end

local function glyphPlacements(resources: renderer.Resources): { lunette.GlyphPlacement }
  local tree = lunette.newLayoutTree()
  tree:apply {
    { op = 'create', id = 1, kind = 'text', text = 'MWI8', textStyle = { family = 'Iosevka', size = 0.03 } },
  }
  tree:compute(1)
  local shaped = assert(tree:textLayout(1))[1].glyphs
  testing.expect.equal(#shaped, 4, 'four actual shaped glyphs')
  local placements = {}
  local deadline = os.clock() + 30
  repeat
    renderer.beginFrame(resources)
    local pending = false
    for index, glyph in shaped do
      local placement, failure, waiting = resources.atlas:glyph(glyph.face, glyph.id)
      assert(failure == nil, failure)
      placements[index] = placement
      pending = pending or waiting
    end
    if not pending then
      break
    end
    assert(os.clock() < deadline, 'the native atlas did not finish generating the glyphs')
  until false
  for index = 1, 4 do
    assert(placements[index], 'a shaped letter has no native atlas placement')
    testing.expect.equal(placements[index].page, placements[1].page, 'the glyph boundary counts share one real page')
  end
  return placements
end

local function atlasTextures(
  resources: renderer.Resources,
  placements: { lunette.GlyphPlacement },
  keep: Keep
): { [number]: Texture }
  local textures = {}
  for _, placement in placements do
    local page = placement.page
    if not textures[page] then
      local atlas = resources.atlas
      local blob = keep(lovr.data.newBlob(assert(atlas:pixels(page)), 'upload oracle atlas'))
      local image = keep(lovr.data.newImage(atlas.pageSize, atlas.pageSize, 'rgba8', blob))
      textures[page] = keep(lovr.graphics.newTexture(image, { mipmaps = false, linear = true }))
    end
  end
  return textures
end

-- Fixed strides and capacities keep the table-upload oracle independent of the renderer's upload implementation.
local function tableBatches(
  pass: Pass,
  name: string,
  data: { number },
  total: number,
  stride: number,
  capacity: number,
  mesh: Mesh,
  transform: Mat4
): ()
  for first = 0, total - 1, capacity do
    local count = math.min(capacity, total - first)
    local batch = table.create(stride * capacity, 0)
    for index = 1, count * stride do
      batch[index] = data[first * stride + index]
    end
    pass:send(name, { batch })
    pass:draw(mesh, transform, count)
  end
end

local function oracle(
  resources: renderer.Resources,
  textures: { [number]: Texture },
  pass: Pass,
  panel: Panel,
  packed: Packed,
  blocked: boolean
): ()
  local scrim = { 0, 0, 0, if blocked then 0.45 else 0 }
  pass:push 'state'
  pass:setCullMode 'none'
  pass:setBlendMode('alpha', 'alphamultiply')
  pass:setColor(1, 1, 1, 1)
  if packed.count > 0 then
    pass:setShader(resources.boxShader)
    pass:send('panelScrim', scrim)
    pass:send('panelSize', { panel.width, panel.height, 0, 0 })
    pass:send('panelCurve', { panel.curve, if panel.curve > 0 then 1 else 0, 0, 0 })
    pass:send('edgeLight', THEME.colors.edgeLight)
    pass:send('edgeDark', THEME.colors.edgeDark)
    local mesh = if panel.curve > 0 then resources.grid else resources.mesh
    tableBatches(pass, 'Boxes', packed.boxes, packed.count, 28, 128, mesh, lovr.math.mat4(panel.pose))
  end
  if next(packed.glyphCounts) then
    pass:setShader(resources.glyphShader)
    pass:setDepthWrite(false)
    pass:send('panelScrim', scrim)
    pass:send('panelPose', lovr.math.mat4(panel.pose))
    pass:send('panelCurve', { panel.curve, 0, 0, 0 })
    pass:send('panelSize', { panel.width, panel.height, 0, 0 })
    local range = resources.atlas.range / resources.atlas.pageSize
    pass:send('glyphRange', { range, range, 0, 0 })
    for page, count in packed.glyphCounts do
      if count > 0 then
        pass:setMaterial(assert(textures[page]))
        tableBatches(pass, 'Glyphs', packed.glyphs[page], count, 20, 200, resources.quad, lovr.math.mat4())
      end
    end
    pass:setMaterial(nil)
  end
  pass:pop 'state'
end

local function packedArrays(): Packed
  return { boxes = {}, count = 0, glyphs = {}, glyphCounts = {}, images = {}, volumes = {} }
end

local function fill(
  packed: Packed,
  boxCount: number,
  glyphCount: number,
  phase: number,
  placements: { lunette.GlyphPlacement }
): ()
  packed.count = boxCount
  -- Only logical counts shrink: the existing records after each active prefix deliberately remain in the arrays.
  table.clear(packed.glyphCounts)
  for index = 1, boxCount do
    local column, row = (index - 1) % 17, math.floor((index - 1) / 17)
    local x, y = 0.02 + column * 0.056 + phase % 3 * 0.0006, 0.016 + row * 0.041
    local values = {
      x,
      y,
      0.038 + index % 3 * 0.001,
      0.027 + index % 4 * 0.001,
      0.005 + (index + phase) % 5 * 0.001,
      0.004,
      index % 4 * 0.001,
      index % 3 * 0.0006,
      0.15 + (index + phase) % 7 * 0.1,
      0.2 + (index * 3 + phase) % 6 * 0.1,
      0.65,
      0.55 + index % 4 * 0.1,
      0.8,
      0.3,
      0.12,
      0.85,
      0.2,
      0.45,
      0.7,
      0.8,
      x + (if index % 9 == 0 then 0.012 else -0.02),
      0,
      1,
      0.72,
      index % 2 * 0.001,
      ((index + phase) % 5 - 2) * 0.08,
      0,
      0,
    }
    for slot, value in values do
      packed.boxes[(index - 1) * 28 + slot] = value
    end
  end
  for index = 1, glyphCount do
    local placement = placements[(index + phase) % #placements + 1]
    local page = placement.page
    local count = packed.glyphCounts[page] or 0
    packed.glyphCounts[page] = count + 1
    local data = packed.glyphs[page] or {}
    packed.glyphs[page] = data
    local x = 0.018 + (index - 1) % 21 * 0.045 + phase % 3 * 0.0006
    local baseline = 0.04 + math.floor((index - 1) / 21) * 0.034
    local size = 0.027 + (index + phase) % 3 * 0.002
    local values = {
      x + placement.left * size,
      baseline - placement.top * size,
      placement.width * size,
      placement.height * size,
      placement.u0,
      placement.v0,
      placement.u1,
      placement.v1,
      0.2 + (index + phase) % 6 * 0.1,
      0.75,
      0.15 + (index * 3 + phase) % 7 * 0.1,
      0.6 + index % 4 * 0.1,
      x + (if index % 9 == 0 then 0.009 else -0.02),
      0,
      1,
      0.72,
      0.015 + (index + phase) % 4 * 0.001,
      0,
      0,
      0,
    }
    for slot, value in values do
      data[count * 20 + slot] = value
    end
  end
end

local function target(keep: Keep): (Texture, Pass)
  local texture = keep(lovr.graphics.newTexture(WIDTH, HEIGHT, {
    format = 'rgba8',
    linear = false,
    mipmaps = false,
    usage = { 'render', 'transfer' },
  }))
  local depth = keep(lovr.graphics.newTexture(WIDTH, HEIGHT, { format = 'd32f', usage = 'render' }))
  local pass = keep(lovr.graphics.newPass { texture = texture, depth = depth, samples = 1 })
  pass:setClear(unpack(BACKGROUND))
  pass:setViewPose(1, lovr.math.mat4():target(vector.pack(0, 0, 1.2), vector.zero, vector.pack(0, 1, 0)))
  pass:setProjection(1, lovr.math.mat4():perspective(math.rad(40), WIDTH / HEIGHT, 0.01, 0))
  return texture, pass
end

local function compare(
  resources: renderer.Resources,
  textures: { [number]: Texture },
  packed: Packed,
  placements: { lunette.GlyphPlacement },
  steps: { Step },
  label: string
): ()
  scope(function(keep: Keep): ()
    local actualTarget, actualPass = target(keep)
    local expectedTarget, expectedPass = target(keep)
    local visible = false
    for _, step in steps do
      if step.beginFrame then
        renderer.beginFrame(resources)
      end
      fill(packed, step.boxes, step.glyphs, step.phase, placements)
      visible = visible or step.boxes > 0 or step.glyphs > 0
      renderer.draw(
        resources,
        actualPass,
        step.panel,
        packed,
        THEME,
        step.blocked,
        function(_label: string, draw: () -> ()): boolean
          draw()
          return true
        end
      )
      oracle(resources, textures, expectedPass, step.panel, packed, step.blocked)
      if step.endFrame then
        renderer.endFrame(resources)
      end
    end
    -- All draws, including a second beginFrame, are recorded before any GPU submission.
    lovr.graphics.submit { actualPass, expectedPass }
    local actualReadback = keep(actualTarget:newReadback())
    local expectedReadback = keep(expectedTarget:newReadback())
    lovr.graphics.submit {}
    actualReadback:wait()
    expectedReadback:wait()
    local actual = keep(assert(actualReadback:getImage()))
    local expected = keep(assert(expectedReadback:getImage()))
    local different, colored = 0, 0
    for y = 0, HEIGHT - 1 do
      for x = 0, WIDTH - 1 do
        local ar, ag, ab, aa = actual:getPixel(x, y)
        local er, eg, eb, ea = expected:getPixel(x, y)
        if math.max(math.abs(ar - er), math.abs(ag - eg), math.abs(ab - eb), math.abs(aa - ea)) > 1 / 255 then
          different += 1
        end
        if
          math.max(math.abs(er - BACKGROUND[1]), math.abs(eg - BACKGROUND[2]), math.abs(eb - BACKGROUND[3])) > 0.05
        then
          colored += 1
        end
      end
    end
    testing.expect.equal(different, 0, `{label}: pixels differing from independent table sends`)
    testing.expect.equal(colored > 0, visible, `{label}: the oracle draws nonempty input only`)
  end)
end

local function panel(curve: number, pose: Mat4?): Panel
  return { width = 1, height = 0.72, curve = curve, pose = pose or lovr.math.newMat4() }
end

local function step(boxes: number, glyphs: number, phase: number, surface: Panel): Step
  return { boxes = boxes, glyphs = glyphs, phase = phase, panel = surface, beginFrame = true, endFrame = true }
end

test('box uploads match table sends across batching boundaries, shrinking tails, and changing frames', function()
  scope(function(keep: Keep, defer: Defer): ()
    local resources = acquire(defer)
    local placements = glyphPlacements(resources)
    local textures = atlasTextures(resources, placements, keep)
    local packed = packedArrays()
    local flat = panel(0, lovr.math.newMat4():rotate(0.18, 0, 1, 0))
    local curved = panel(1.4)
    for phase, count in { 0, 1, 128, 129, 257, 128, 1, 0, 257 } do
      local current = step(count, 0, phase, if phase % 2 == 0 then curved else flat)
      current.blocked = phase % 3 == 0
      compare(resources, textures, packed, placements, { current }, `boxes {count}, frame {phase}`)
      if phase > 5 then
        testing.expect.equal(#packed.boxes, 257 * 28, 'shrinking preserves the packed box tail')
      end
    end
  end)
end)

test('native atlas glyph uploads match table sends across batching boundaries and shrinking tails', function()
  scope(function(keep: Keep, defer: Defer): ()
    local resources = acquire(defer)
    local placements = glyphPlacements(resources)
    local textures = atlasTextures(resources, placements, keep)
    local packed = packedArrays()
    for phase, count in { 0, 1, 200, 201, 401, 200, 1, 0, 401 } do
      local current = step(0, count, phase, panel(if phase % 2 == 0 then 1.4 else 0))
      current.blocked = phase % 3 == 0
      compare(resources, textures, packed, placements, { current }, `glyphs {count}, frame {phase}`)
      if phase > 5 then
        local records = 0
        for _, data in packed.glyphs do
          records += #data / 20
        end
        testing.expect.truthy(records >= 401, 'shrinking preserves the packed glyph tails')
      end
    end
  end)
end)

test('forced upload padding matches table sends across batches, shrinking tails, and zero counts', function()
  scope(function(keep: Keep, defer: Defer): ()
    local resources = acquire(defer)
    local alignment = math.max(16, lovr.graphics.getLimits().uniformBufferAlign)
    resources.boxes.stride = math.ceil(resources.boxes.bytes / alignment) * alignment + alignment
    resources.glyphData.stride = math.ceil(resources.glyphData.bytes / alignment) * alignment + alignment
    testing.expect.equal(resources.boxes.stride % alignment, 0, 'box stride respects uniform-buffer alignment')
    testing.expect.equal(resources.glyphData.stride % alignment, 0, 'glyph stride respects uniform-buffer alignment')
    local placements = glyphPlacements(resources)
    local textures = atlasTextures(resources, placements, keep)
    local packed = packedArrays()
    local surface = panel(0.8)
    compare(resources, textures, packed, placements, {
      step(257, 401, 0, surface),
      step(129, 201, 1, surface),
      step(0, 0, 2, surface),
    }, 'forced padding')
  end)
end)

test('panels and repeated beginFrame calls retain distinct uploads until one deferred submission', function()
  scope(function(keep: Keep, defer: Defer): ()
    local resources = acquire(defer)
    local placements = glyphPlacements(resources)
    local textures = atlasTextures(resources, placements, keep)
    local packed = packedArrays()
    local left = panel(0, lovr.math.newMat4():translate(-0.27, 0.19, 0):rotate(0.15, 0, 1, 0):scale(0.48))
    local right = panel(1.4, lovr.math.newMat4():translate(0.27, 0.19, 0):scale(0.48))
    local lower = panel(0.8, lovr.math.newMat4():translate(0, -0.2, 0.01):scale(0.45))
    for frame = 1, 3 do
      local first = step(257, 401, frame * 3, left)
      local second = step(129, 201, frame * 3 + 1, right)
      first.endFrame, second.beginFrame, second.blocked = false, false, true
      local third = step(1, 1, frame * 3 + 2, lower)
      compare(resources, textures, packed, placements, { first, second, third }, `deferred frame {frame}`)
    end
  end)
end)

return test
