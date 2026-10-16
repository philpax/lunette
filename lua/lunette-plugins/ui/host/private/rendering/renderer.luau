-- Draws packed panels: one instanced draw per batch of boxes through the toolkit shader, then text by line.

local uiHost = require '@lunette-contracts/ui-host'
local records = require '../records'
local shader = require './shader'
local fonts = require './fonts'
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
  textShader: Shader,
  imageShader: Shader,
  batch: { number },
  images: images.Cache,
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

-- Creates the GPU resources. The returned function releases them.
function renderer.acquire(): (Resources, () -> ())
  local made: { { release: (any) -> () } } = {}
  local cache = images.new()
  local function keep<T>(value: T): T
    table.insert(made, value :: any)
    return value
  end
  local function release(): ()
    images.release(cache)
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
      textShader = keep(lovr.graphics.newShader(shader.textVertex, shader.textFragment, { label = 'ui/text' })),
      imageShader = keep(lovr.graphics.newShader(shader.textVertex, shader.imageFragment, { label = 'ui/images' })),
      images = cache,
      batch = table.create(shader.SLOTS * shader.BATCH * 4, 0),
    }
  end)
  if not ok then
    release()
    error(result, 0)
  end
  return result, release
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

local function drawTexts(
  resources: Resources,
  pass: Pass,
  panel: records.Panel,
  packed: pack.Packed,
  registry: fonts.Registry
): ()
  if #packed.texts == 0 then
    return
  end
  pass:setShader(resources.textShader)
  pass:setDepthWrite(false)
  local pose = centre(panel)
  pass:send('panelInverse', lovr.math.mat4(pose):invert())
  pass:send('panelPose', pose)
  pass:send('panelCurve', { panel.curve, 0, 0, 0 })
  pass:send('panelSize', { panel.width, panel.height, 0, 0 })
  local halfWidth, halfHeight = panel.width / 2, panel.height / 2
  for _, run in packed.texts do
    local face = fonts.match(registry, run.family, run.weight)
    local font = if face then fonts.font(face) else lovr.graphics.getDefaultFont()
    pass:setFont(font)
    local measured = font:getWidth(run.text)
    local stretch = if measured > 0 and run.width > 0 then run.width / (measured * run.size) else 1
    if stretch < 0.85 or stretch > 1.15 then
      stretch = 1
    end
    local ascent = font:getAscent() * run.size
    pass:setColor(run.color[1], run.color[2], run.color[3], run.color[4] or 1)
    pass:send('textClip', run.clip)
    local transform = lovr.math
      .mat4(pose)
      :translate(run.x - halfWidth, halfHeight - run.baseline + ascent, run.z)
      :scale(run.size * stretch, run.size, run.size)
    pass:text(run.text, transform, 0, 'left', 'top')
  end
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
  theme: uiHost.Theme,
  registry: fonts.Registry
): ()
  pass:push 'state'
  local ok, failure = pcall(function(): ()
    pass:setCullMode 'none'
    pass:setBlendMode('alpha', 'alphamultiply')
    pass:setColor(1, 1, 1, 1)
    drawBoxes(resources, pass, panel, packed, theme)
    drawImages(resources, pass, panel, packed)
    drawTexts(resources, pass, panel, packed, registry)
  end)
  pass:pop 'state'
  if not ok then
    error(failure, 0)
  end
end

return renderer
