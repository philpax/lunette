local testing = require '@testing'
local theme = require '@lunette-contracts/theme'
local pack = require '../private/rendering/pack'
local expect = testing.expect
local test = testing.suite()

local function environment(): any
  testing.native()
  local session = testing.start { 'theme' }
  local tokens = assert(session:observe(theme.capability).service):current()
  return {
    theme = function(): any
      return tokens
    end,
  }
end

local function numbers(actual: { number }, wanted: { number }, context: string, offset: number?): ()
  for index, value in wanted do
    expect.near(actual[(offset or 0) + index], value, 1e-9, `{context}[{index}]`)
  end
end

local function slots(...: { number }): { number }
  local result = {}
  for _, slot in { ... } do
    for _, value in slot do
      table.insert(result, value)
    end
  end
  return result
end

local UNCLIPPED = { -1e6, -1e6, 1e6, 1e6 }
local EDGE = { 0.0004, 0.25, 0, 0 }
local ATLAS_A = { 0.125, 0.25, 0.5, 0.75 }
local ATLAS_B = { 0.5, 0.125, 0.75, 0.5 }

local function expectedGlyph(
  bounds: { number },
  atlas: { number },
  alpha: number,
  clip: { number },
  z: number
): { number }
  return slots(bounds, atlas, { 0.25, 0.5, 0.75, alpha }, clip, { z, 0, 0, 0 })
end

local function instances(actual: { number }, count: number, wanted: { { number } }, stride: number, context: string): ()
  expect.equal(count, #wanted, `{context} count`)
  for index, row in wanted do
    expect.equal(#row, stride, `{context} expected stride`)
    numbers(actual, row, `{context} instance {index}`, (index - 1) * stride)
  end
end

local function fields(actual: any, wanted: any, context: string): ()
  for key, value in wanted do
    if type(value) == 'number' then
      expect.near(actual[key], value, 1e-9, `{context}.{key}`)
    else
      expect.equal(actual[key], value, `{context}.{key}`)
    end
  end
end

local function glyphBuffers(packed: pack.Packed, wanted: { [number]: { { number } } }): ()
  for page, count in packed.glyphCounts do
    expect.truthy(wanted[page], `unexpected active glyph page {page}`)
    instances(packed.glyphs[page], count, wanted[page], 20, `glyph page {page}`)
  end
  for page, rows in wanted do
    expect.equal(packed.glyphCounts[page], #rows, `glyph page {page} count`)
  end
end

local function node(x: number, y: number, z: number, primitives: { any }): any
  return {
    x = x,
    y = y,
    z = z,
    width = 8,
    height = 6,
    elevation = 0.25,
    lift = 0.125,
    kind = { name = 'test/packed', registration = {} },
    channels = {},
    host = {},
    children = {},
    primitives = primitives,
  }
end

local function box(): any
  return {
    kind = 'box',
    x = 0.25,
    y = 0.5,
    width = 2,
    height = 1,
    offset = 0.125,
    radius = 0.1,
    border = 0.025,
    rotation = 0.25,
    edges = true,
    fill = { 0.2, 0.4, 0.6, 0.8 },
    borderColor = { 1, 0.5, 0 },
    side = { 0.3, 0.2, 0.1, 0.4 },
  }
end

local function text(): any
  return {
    kind = 'text',
    x = 0.5,
    y = 0.25,
    offset = 0.015625,
    color = { 0.25, 0.5, 0.75 },
    lines = {
      {
        baseline = 1,
        glyphs = {
          { face = 3, id = 11, size = 2, x = 0.25, xOffset = 0.125, yOffset = 0.125 },
          { face = 3, id = 0, size = 2, x = 4, xOffset = 0, yOffset = 0 },
        },
      },
      { baseline = 3, glyphs = { { face = 4, id = 22, size = 1, x = 1, xOffset = 0, yOffset = -0.25 } } },
    },
  }
end

local function primitives(source: any): { any }
  return {
    box(),
    {
      kind = 'image',
      source = source,
      x = 0.5,
      y = 0.25,
      width = 1.5,
      height = 0.75,
      offset = 0.0625,
      tint = { 0.8, 0.6, 0.4, 0.5 },
    },
    { kind = 'volume', x = 1, y = 1, width = 1, height = 0.5, offset = 0.03125 },
    text(),
  }
end

local function glyphs(face: number, id: number): pack.Glyph?
  if id == 11 or id == 33 then
    expect.equal(face, 3)
    return {
      page = if id == 33 then 9 else 2,
      left = 0.25,
      top = 0.5,
      width = 0.75,
      height = 1,
      u0 = 0.125,
      v0 = 0.25,
      u1 = 0.5,
      v1 = 0.75,
    }
  elseif id == 22 then
    expect.equal(face, 4)
    return {
      page = 5,
      left = -0.25,
      top = 0.75,
      width = 0.5,
      height = 0.75,
      u0 = 0.5,
      v0 = 0.125,
      u1 = 0.75,
      v1 = 0.5,
    }
  end
  expect.equal(id, 0, 'only the outline-free glyph is absent')
  return nil
end

local function mixed(): any
  local source = { name = 'packed-image' }
  local root = node(10, 20, 1, primitives(source))
  root.kind.name = 'test/root'
  root.kind.registration.clip = true
  root.channels.opacity = { value = 0.5 }
  root.host.focusVisible = true
  local clipping = node(12, 21, 2, { primitives(source)[2] })
  clipping.width, clipping.height = 3, 3
  clipping.kind.registration.clip = true
  clipping.channels.opacity = { value = 0.5 }
  local grandchild = node(13, 22, 3, primitives(source))
  grandchild.width, grandchild.height = 4, 2
  grandchild.elevation, grandchild.lift = 1, 0.5
  grandchild.channels.opacity = { value = 0.5 }
  table.insert(grandchild.primitives, {
    kind = 'volume',
    x = 1.75,
    y = 1,
    width = 1,
    height = 0.5,
    offset = 0,
  })
  table.insert(grandchild.primitives, {
    kind = 'volume',
    x = 1,
    y = 1,
    width = 1,
    height = 0.5,
    offset = 0,
    failed = true,
  })
  clipping.children = { grandchild }
  local sibling = node(11, 24, 4, primitives(source))
  sibling.width, sibling.height = 3, 2
  sibling.channels.opacity = { value = 2 }
  sibling.primitives[1].depth = 0.0625
  local outside = node(18, 21, 50, primitives(source))
  local invisible = node(12, 22, 60, primitives(source))
  invisible.channels.opacity = { value = 0.01 }
  root.children = { clipping, outside, invisible, sibling }
  local clip = { 30, 40, 34, 44 }
  local first, second = primitives(source), primitives(source)
  second[1].side = nil
  return {
    panel = {
      root = root,
      fade = { value = 0.5 },
      ghosts = {
        {
          opacity = { value = 0.25 },
          nodes = {
            { x = 30, y = 40, z = 5, parentSurface = 4, clip = clip, primitives = first },
            { x = 50, y = 60, z = 6, parentSurface = 8, primitives = second },
          },
        },
      },
    },
    source = source,
    clip = clip,
    volumes = { root.primitives[3], grandchild.primitives[3], sibling.primitives[3], first[3], second[3] },
  }
end

local function checkMixed(packed: pack.Packed, fixture: any): ()
  instances(packed.boxes, packed.count, {
    slots(
      { 10.25, 20.5, 2, 1 },
      { 1.125, 0.5, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.2 },
      { 1, 0.5, 0, 0.25 },
      { 0.3, 0.2, 0.1, 0.1 },
      UNCLIPPED,
      EDGE
    ),
    slots(
      { 9.9982, 19.9982, 8.0036, 6.0036 },
      { 1.00054, 0, 0.0033, 0.0012 },
      { 0, 0, 0, 0 },
      { 159 / 255, 211 / 255, 230 / 255, 0.25 },
      { 0, 0, 0, 0 },
      UNCLIPPED,
      { 0, 0, 0, 0 }
    ),
    slots(
      { 13.25, 22.5, 2, 1 },
      { 3.125, 1.625, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.05 },
      { 1, 0.5, 0, 0.0625 },
      { 0.3, 0.2, 0.1, 0.025 },
      { 12, 21, 15, 24 },
      EDGE
    ),
    slots(
      { 11.25, 24.5, 2, 1 },
      { 4.125, 0.0625, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.2 },
      { 1, 0.5, 0, 0.25 },
      { 0.3, 0.2, 0.1, 0.1 },
      { 10, 20, 18, 26 },
      EDGE
    ),
    slots(
      { 30.25, 40.5, 2, 1 },
      { 5.125, 1.125, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.1 },
      { 1, 0.5, 0, 0.125 },
      { 0.3, 0.2, 0.1, 0.05 },
      { 30, 40, 34, 44 },
      EDGE
    ),
    slots(
      { 50.25, 60.5, 2, 1 },
      { 6.125, 0, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.1 },
      { 1, 0.5, 0, 0.125 },
      { 0.2, 0.4, 0.6, 0.1 },
      UNCLIPPED,
      EDGE
    ),
  }, 28, 'boxes in tree, focus-ring, and ghost order')
  glyphBuffers(packed, {
    [2] = {
      expectedGlyph({ 11.375, 20.375, 1.5, 2 }, ATLAS_A, 0.25, UNCLIPPED, 1.015905),
      expectedGlyph({ 14.375, 22.375, 1.5, 2 }, ATLAS_A, 0.0625, { 12, 21, 15, 24 }, 3.015905),
      expectedGlyph({ 12.375, 24.375, 1.5, 2 }, ATLAS_A, 0.25, { 10, 20, 18, 26 }, 4.015905),
      expectedGlyph({ 31.375, 40.375, 1.5, 2 }, ATLAS_A, 0.125, { 30, 40, 34, 44 }, 5.015905),
      expectedGlyph({ 51.375, 60.375, 1.5, 2 }, ATLAS_A, 0.125, UNCLIPPED, 6.015905),
    },
    [5] = {
      expectedGlyph({ 11.25, 22.25, 0.5, 0.75 }, ATLAS_B, 0.25, UNCLIPPED, 1.015905),
      expectedGlyph({ 14.25, 24.25, 0.5, 0.75 }, ATLAS_B, 0.0625, { 12, 21, 15, 24 }, 3.015905),
      expectedGlyph({ 12.25, 26.25, 0.5, 0.75 }, ATLAS_B, 0.25, { 10, 20, 18, 26 }, 4.015905),
      expectedGlyph({ 31.25, 42.25, 0.5, 0.75 }, ATLAS_B, 0.125, { 30, 40, 34, 44 }, 5.015905),
      expectedGlyph({ 51.25, 62.25, 0.5, 0.75 }, ATLAS_B, 0.125, UNCLIPPED, 6.015905),
    },
  })
  local images = {
    { x = 10.5, y = 20.25, z = 1.06276 },
    { x = 12.5, y = 21.25, z = 2.06275 },
    { x = 13.5, y = 22.25, z = 3.06276 },
    { x = 11.5, y = 24.25, z = 4.06276 },
    { x = 30.5, y = 40.25, z = 5.06276 },
    { x = 50.5, y = 60.25, z = 6.06276 },
  }
  local clips = {
    { -1e6, -1e6, 1e6, 1e6 },
    { 10, 20, 18, 26 },
    { 12, 21, 15, 24 },
    { 10, 20, 18, 26 },
    fixture.clip,
    { -1e6, -1e6, 1e6, 1e6 },
  }
  local alphas = { 0.125, 0.0625, 0.03125, 0.125, 0.0625, 0.0625 }
  expect.equal(#packed.images, 6)
  for index, wanted in images do
    local image = packed.images[index]
    fields(image, wanted, `image {index}`)
    fields(image, { source = fixture.source, width = 1.5, height = 0.75 }, `image {index}`)
    numbers(image.tint, { 0.8, 0.6, 0.4, alphas[index] }, `image {index} tint`)
    numbers(image.clip, clips[index], `image {index} clip`)
  end
  expect.equal(packed.images[2].clip, packed.images[4].clip, 'siblings retain the same inherited clip')
  expect.equal(packed.images[5].clip, fixture.clip, 'a ghost retains its supplied clip array')
  expect.equal(packed.images[6].clip, packed.images[1].clip, 'an unclipped ghost uses the unbounded clip')
  expect.truthy(packed.images[2].clip ~= packed.images[3].clip, 'nested clipping keeps a distinct array')
  local volumes = {
    { x = 11, y = 21, z = 1.03127, opacity = 0.25, kind = 'test/root' },
    { x = 14, y = 23, z = 3.03127, opacity = 0.0625, kind = 'test/packed' },
    { x = 12, y = 25, z = 4.03127, opacity = 0.25, kind = 'test/packed' },
    { x = 31, y = 41, z = 5.03127, opacity = 0.125, kind = 'exiting node' },
    { x = 51, y = 61, z = 6.03127, opacity = 0.125, kind = 'exiting node' },
  }
  expect.equal(#packed.volumes, 5, 'partial and failed volumes are absent')
  for index, wanted in volumes do
    fields(packed.volumes[index], wanted, `volume {index}`)
    fields(packed.volumes[index], { primitive = fixture.volumes[index], width = 1, height = 0.5 }, `volume {index}`)
  end
end

test('mixed primitives retain placements across clipped descendants, siblings, focus rings, and ghosts', function(): ()
  local env, fixture = environment(), mixed()
  local calls = 0
  local packed = pack.run(fixture.panel, env, {}, function(face: number, id: number): pack.Glyph?
    calls += 1
    return glyphs(face, id)
  end)
  checkMixed(packed, fixture)
  expect.equal(calls, 15, 'only five visible text records request their three glyphs')
end)

test('reusing packed output shrinks active buffers and clears images, volumes, and old glyph pages', function(): ()
  local env, fixture = environment(), mixed()
  local packed = pack.run(fixture.panel, env, {}, glyphs)
  checkMixed(packed, fixture)
  local boxes, pages, images, volumes = packed.boxes, packed.glyphs, packed.images, packed.volumes
  local oldPage = pages[2]
  local label = text()
  label.lines = {
    {
      baseline = 1,
      glyphs = {
        { face = 3, id = 33, size = 2, x = 0.25, xOffset = 0.125, yOffset = 0.125 },
      },
    },
  }
  local root = node(70, 80, 7, { box(), label })
  local result = pack.run({ root = root, fade = { value = 2 }, ghosts = {} }, env, {}, glyphs, packed)
  expect.equal(result, packed)
  expect.equal(result.boxes, boxes)
  expect.equal(result.glyphs, pages)
  expect.equal(result.images, images)
  expect.equal(result.volumes, volumes)
  expect.equal(result.glyphs[2], oldPage, 'inactive backing storage may remain')
  instances(result.boxes, result.count, {
    slots(
      { 70.25, 80.5, 2, 1 },
      { 7.125, 0.5, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.8 },
      { 1, 0.5, 0, 1 },
      { 0.3, 0.2, 0.1, 0.4 },
      UNCLIPPED,
      EDGE
    ),
  }, 28, 'short frame')
  glyphBuffers(result, { [9] = { expectedGlyph({ 71.375, 80.375, 1.5, 2 }, ATLAS_A, 1, UNCLIPPED, 7.015885) } })
  expect.equal(#images, 0)
  expect.equal(#volumes, 0)
  expect.equal(pack.run({ ghosts = {} }, env, {}, glyphs, result), result)
  expect.equal(result.count, 0)
  glyphBuffers(result, {})
  expect.equal(#images, 0)
  expect.equal(#volumes, 0)
end)

test('a nested pack during glyph lookup cannot overwrite the outer invocation placement', function(): ()
  local env, fixture = environment(), mixed()
  local source = { name = 'outer-image' }
  local outerPrimitives = primitives(source)
  outerPrimitives = { outerPrimitives[4], outerPrimitives[1], outerPrimitives[2], outerPrimitives[3] }
  local root = node(7, 9, 1, {})
  root.width, root.height = 8, 8
  root.kind.registration.clip = true
  root.channels.opacity = { value = 0.5 }
  local child = node(8, 10, 2, outerPrimitives)
  child.channels.opacity = { value = 0.5 }
  root.children = { child }
  local nested: pack.Packed? = nil
  local calls = 0
  local outer = pack.run(
    { root = root, fade = { value = 0.5 }, ghosts = {} },
    env,
    {},
    function(face: number, id: number): pack.Glyph?
      calls += 1
      if not nested then
        nested = pack.run(fixture.panel, env, {}, glyphs)
      end
      return glyphs(face, id)
    end
  )
  expect.equal(calls, 3)
  checkMixed(assert(nested), fixture)
  instances(outer.boxes, outer.count, {
    slots(
      { 8.25, 10.5, 2, 1 },
      { 2.12501, 0.50001, 0.1, 0.025 },
      { 0.2, 0.4, 0.6, 0.1 },
      { 1, 0.5, 0, 0.125 },
      { 0.3, 0.2, 0.1, 0.05 },
      { 7, 9, 15, 17 },
      EDGE
    ),
  }, 28, 'outer boxes after nested packing')
  glyphBuffers(outer, {
    [2] = { expectedGlyph({ 9.375, 10.375, 1.5, 2 }, ATLAS_A, 0.125, { 7, 9, 15, 17 }, 2.015875) },
    [5] = { expectedGlyph({ 9.25, 12.25, 0.5, 0.75 }, ATLAS_B, 0.125, { 7, 9, 15, 17 }, 2.015875) },
  })
  expect.equal(#outer.images, 1)
  fields(
    outer.images[1],
    { source = source, x = 8.5, y = 10.25, width = 1.5, height = 0.75, z = 2.06277 },
    'outer image'
  )
  numbers(outer.images[1].tint, { 0.8, 0.6, 0.4, 0.0625 }, 'outer image tint')
  numbers(outer.images[1].clip, { 7, 9, 15, 17 }, 'outer image clip')
  expect.equal(#outer.volumes, 1)
  fields(outer.volumes[1], {
    primitive = outerPrimitives[4],
    x = 9,
    y = 11,
    width = 1,
    height = 0.5,
    z = 2.03128,
    opacity = 0.125,
    kind = 'test/packed',
  }, 'outer volume')
end)

return test
