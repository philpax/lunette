-- Draws packed panels: one instanced draw per batch of boxes through the toolkit shader, then images, then one
-- instanced draw per batch of glyphs on each page of the native glyph atlas.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local records = require '../records'
local shader = require './shader'
local pack = require './pack'
local images = require './images'

local renderer = {}

-- Segments per rounded corner of the template prism.
local CORNER_SEGMENTS = 6

export type Resources = {
  mesh: Mesh,
  -- A flat grid across the box, which the vertex stage can bend; boxes on curved panels use it.
  grid: Mesh,
  boxShader: Shader,
  glyphShader: Shader,
  imageShader: Shader,
  -- A unit quad from 0 to 1, y down, that each glyph instance scales.
  quad: Mesh,
  batch: { number },
  glyphBatch: { number },
  images: images.Cache,
  atlas: lunette.GlyphAtlas,
  -- A texture per atlas page and the page revision it holds.
  pages: { [number]: { texture: Texture, revision: number } },
  -- Placements by face and glyph id; false marks a glyph that draws nothing.
  placements: { [number]: { [number]: pack.Glyph | false } },
  -- Reports a glyph that could not be generated, once per glyph.
  report: (string) -> (),
}

export type Template = { vertices: { { number } }, indices: { number } }

-- A rounded prism of unit parameters: the vertex shader scales the corners by the box's size and radius. Corners
-- run clockwise in panel coordinates, where y grows downward.
function renderer.template(segments: number): Template
  local corners = { { 1, -1, -90 }, { 1, 1, 0 }, { -1, 1, 90 }, { -1, -1, 180 } }
  local ring: { { number } } = {}
  for _, corner in corners do
    for step = 0, segments do
      local angle = math.rad(corner[3] + 90 * step / segments)
      ring[#ring + 1] = { corner[1], corner[2], math.cos(angle), math.sin(angle) }
    end
  end
  local vertices: { { number } } = {}
  local indices: { number } = {}
  -- The top face is a fan around the centre.
  vertices[1] = { 0, 0, 1, 0, 0, 1, 0, 0 }
  for _, point in ring do
    vertices[#vertices + 1] = { point[1], point[2], 1, 0, 0, 1, point[3], point[4] }
  end
  local count = #ring
  for index = 1, count do
    local following = index % count + 1
    table.insert(indices, 1)
    table.insert(indices, 1 + index)
    table.insert(indices, 1 + following)
  end
  -- Each side quad joins a top and a bottom vertex at two ring positions; side normals have no z.
  local sides = #vertices
  for _, point in ring do
    vertices[#vertices + 1] = { point[1], point[2], 1, point[3], point[4], 0, point[3], point[4] }
    vertices[#vertices + 1] = { point[1], point[2], 0, point[3], point[4], 0, point[3], point[4] }
  end
  for index = 1, count do
    local following = index % count + 1
    local top, bottom = sides + (index - 1) * 2 + 1, sides + (index - 1) * 2 + 2
    local nextTop, nextBottom = sides + (following - 1) * 2 + 1, sides + (following - 1) * 2 + 2
    table.insert(indices, top)
    table.insert(indices, bottom)
    table.insert(indices, nextTop)
    table.insert(indices, nextTop)
    table.insert(indices, bottom)
    table.insert(indices, nextBottom)
  end
  return { vertices = vertices, indices = indices }
end

-- Columns of the grid template. Thirty-two keeps the chord error under a millimetre across a metre-wide box on a
-- cylinder of one metre radius.
local GRID_COLUMNS = 32

-- A grid of the top face only, with UV running from -1 to 1 across the box.
function renderer.grid(columns: number): Template
  local vertices: { { number } } = {}
  local indices: { number } = {}
  for column = 0, columns do
    local u = column / columns * 2 - 1
    vertices[#vertices + 1] = { 0, 0, 1, 0, 0, 1, u, -1 }
    vertices[#vertices + 1] = { 0, 0, 1, 0, 0, 1, u, 1 }
  end
  for column = 0, columns - 1 do
    local top, bottom = column * 2 + 1, column * 2 + 2
    table.insert(indices, top)
    table.insert(indices, bottom)
    table.insert(indices, top + 2)
    table.insert(indices, top + 2)
    table.insert(indices, bottom)
    table.insert(indices, bottom + 2)
  end
  return { vertices = vertices, indices = indices }
end

local function quad(keep: <T>(T) -> T): Mesh
  local mesh = keep(lovr.graphics.newMesh({
    { 0, 0, 0, 0, 0, 1, 0, 0 },
    { 1, 0, 0, 0, 0, 1, 1, 0 },
    { 1, 1, 0, 0, 0, 1, 1, 1 },
    { 0, 1, 0, 0, 0, 1, 0, 1 },
  }, { storage = 'gpu' }))
  mesh:setIndices { 1, 2, 3, 1, 3, 4 }
  return mesh
end

-- Creates the GPU resources. The returned function releases them. `report` receives a glyph the atlas could not
-- generate.
function renderer.acquire(report: (string) -> ()): (Resources, () -> ())
  local made: { { release: (any) -> () } } = {}
  local cache = images.new()
  local pages: { [number]: { texture: Texture, revision: number } } = {}
  local function keep<T>(value: T): T
    table.insert(made, value :: any)
    return value
  end
  local function release(): ()
    images.release(cache)
    for _, page in pages do
      page.texture:release()
    end
    table.clear(pages)
    for index = #made, 1, -1 do
      made[index]:release()
    end
  end
  local ok, result = pcall(function(): Resources
    local template = renderer.template(CORNER_SEGMENTS)
    local mesh = keep(lovr.graphics.newMesh(template.vertices, { storage = 'gpu' }))
    mesh:setIndices(template.indices)
    local gridTemplate = renderer.grid(GRID_COLUMNS)
    local grid = keep(lovr.graphics.newMesh(gridTemplate.vertices, { storage = 'gpu' }))
    grid:setIndices(gridTemplate.indices)
    return {
      mesh = mesh,
      grid = grid,
      boxShader = keep(lovr.graphics.newShader(shader.boxVertex, shader.boxFragment, { label = 'ui/boxes' })),
      glyphShader = keep(lovr.graphics.newShader(shader.glyphVertex, shader.glyphFragment, { label = 'ui/glyphs' })),
      imageShader = keep(lovr.graphics.newShader(shader.textVertex, shader.imageFragment, { label = 'ui/images' })),
      quad = quad(keep),
      images = cache,
      batch = table.create(shader.SLOTS * shader.BATCH * 4, 0),
      glyphBatch = table.create(shader.GLYPH_SLOTS * shader.GLYPH_BATCH * 4, 0),
      atlas = lunette.glyphAtlas(),
      pages = pages,
      placements = {},
      report = report,
    }
  end)
  if not ok then
    release()
    error(result, 0)
  end
  return result, release
end

-- Answers a function that finds a glyph's placement in the atlas, remembering each answer, so a glyph crosses into
-- the native atlas once it is placed. A glyph whose field is still being generated draws nothing and is asked for
-- again on a later frame. A glyph the atlas could not generate is remembered as drawing nothing for as long as the
-- resources live, rather than tried and reported again every frame.
function renderer.glyphs(resources: Resources): pack.Glyphs
  local placements = resources.placements
  local atlas = resources.atlas
  return function(face: number, id: number): pack.Glyph?
    local known = placements[face]
    if not known then
      known = {}
      placements[face] = known
    end
    local placement = known[id]
    if placement == nil then
      local found, failure, pending = atlas:glyph(face, id)
      if pending then
        return nil
      end
      if failure then
        resources.report(failure)
      end
      placement = found or false
      known[id] = placement
    end
    return placement or nil
  end
end

-- Starts a frame's drawing, placing the glyphs the atlas's workers have finished since the last frame.
function renderer.beginFrame(resources: Resources): ()
  resources.atlas:update()
end

-- The texture of an atlas page, uploaded again when the page has gained glyphs.
local function page(resources: Resources, index: number): Texture?
  local atlas = resources.atlas
  local revision = atlas:revision(index)
  if revision == nil then
    return nil
  end
  local held = resources.pages[index]
  if held and held.revision == revision then
    return held.texture
  end
  local pixels = atlas:pixels(index)
  if pixels == nil then
    return nil
  end
  local size = atlas.pageSize
  local image = lovr.data.newImage(size, size, 'rgba8', lovr.data.newBlob(pixels, 'ui glyph atlas'))
  if held then
    held.texture:setPixels(image)
    held.revision = revision
    return held.texture
  end
  -- The distance field is data, not colour, so it is sampled without sRGB conversion.
  local texture = lovr.graphics.newTexture(image, {
    mipmaps = false,
    linear = true,
    usage = { 'sample', 'transfer' },
    label = `ui glyph atlas page {index}`,
  })
  resources.pages[index] = { texture = texture, revision = revision }
  return texture
end

-- The local transform of a panel's centre, from its pose.
local function centre(panel: records.Panel): Mat4
  return lovr.math.mat4(panel.pose)
end

local function drawBoxes(
  resources: Resources,
  pass: Pass,
  panel: records.Panel,
  packed: pack.Packed,
  theme: uiHost.Theme
): ()
  if packed.count == 0 then
    return
  end
  pass:setShader(resources.boxShader)
  pass:send('panelSize', { panel.width, panel.height, 0, 0 })
  local curved = panel.curve > 0
  pass:send('panelCurve', { panel.curve, if curved then 1 else 0, 0, 0 })
  local mesh = if curved then resources.grid else resources.mesh
  local light, dark = theme.colors.edgeLight, theme.colors.edgeDark
  pass:send('edgeLight', { light[1], light[2], light[3], light[4] })
  pass:send('edgeDark', { dark[1], dark[2], dark[3], dark[4] })
  local stride = shader.SLOTS * 4
  local batch = resources.batch
  local transform = centre(panel)
  local first = 0
  while first < packed.count do
    local count = math.min(shader.BATCH, packed.count - first)
    table.move(packed.boxes, first * stride + 1, (first + count) * stride, 1, batch)
    pass:send('Boxes', { batch })
    pass:draw(mesh, transform, count)
    first += count
  end
end

local function drawImages(resources: Resources, pass: Pass, panel: records.Panel, packed: pack.Packed): ()
  if #packed.images == 0 then
    return
  end
  pass:setShader(resources.imageShader)
  pass:setDepthWrite(false)
  local pose = centre(panel)
  pass:send('panelInverse', lovr.math.mat4(pose):invert())
  pass:send('panelPose', pose)
  pass:send('panelCurve', { panel.curve, 0, 0, 0 })
  pass:send('panelSize', { panel.width, panel.height, 0, 0 })
  local halfWidth, halfHeight = panel.width / 2, panel.height / 2
  for _, run in packed.images do
    local texture = images.texture(resources.images, run.source, run.width, run.height)
    pass:setMaterial(texture)
    pass:setColor(run.tint[1], run.tint[2], run.tint[3], run.tint[4] or 1)
    pass:send('textClip', run.clip)
    local x = run.x + run.width / 2 - halfWidth
    local y = halfHeight - (run.y + run.height / 2)
    pass:plane(lovr.math.mat4(pose):translate(x, y, run.z):scale(run.width, run.height, 1))
  end
  pass:setMaterial(nil)
end

local function drawGlyphs(resources: Resources, pass: Pass, panel: records.Panel, packed: pack.Packed): ()
  if next(packed.glyphCounts) == nil then
    return
  end
  pass:setShader(resources.glyphShader)
  pass:setDepthWrite(false)
  pass:send('panelPose', centre(panel))
  pass:send('panelCurve', { panel.curve, 0, 0, 0 })
  pass:send('panelSize', { panel.width, panel.height, 0, 0 })
  local atlas = resources.atlas
  local range = atlas.range / atlas.pageSize
  pass:send('glyphRange', { range, range, 0, 0 })
  local stride = shader.GLYPH_SLOTS * 4
  local batch = resources.glyphBatch
  for index, total in packed.glyphCounts do
    local texture = page(resources, index)
    local data = packed.glyphs[index]
    if texture and data and total > 0 then
      pass:setMaterial(texture)
      local first = 0
      while first < total do
        local count = math.min(shader.GLYPH_BATCH, total - first)
        table.move(data, first * stride + 1, (first + count) * stride, 1, batch)
        pass:send('Glyphs', { batch })
        pass:draw(resources.quad, lovr.math.mat4(), count)
        first += count
      end
    end
  end
  pass:setMaterial(nil)
end

-- Ends a frame's drawing, releasing image textures that have gone unused.
function renderer.endFrame(resources: Resources): ()
  images.collect(resources.images)
end

function renderer.draw(
  resources: Resources,
  pass: Pass,
  panel: records.Panel,
  packed: pack.Packed,
  theme: uiHost.Theme
): ()
  pass:push 'state'
  local ok, failure = pcall(function(): ()
    pass:setCullMode 'none'
    pass:setBlendMode('alpha', 'alphamultiply')
    pass:setColor(1, 1, 1, 1)
    drawBoxes(resources, pass, panel, packed, theme)
    drawImages(resources, pass, panel, packed)
    drawGlyphs(resources, pass, panel, packed)
  end)
  pass:pop 'state'
  if not ok then
    error(failure, 0)
  end
end

return renderer
