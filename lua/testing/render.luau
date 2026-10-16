-- Records development-only drawing with real LÖVR transforms and deterministic codepoint font metrics.
-- Text bounds are metric boxes, not rasterized glyph ink.
-- meshFailure and shaderFailure inject one acquisition error; acquisition and release lists record resource counts.
-- Custom meshes and uniforms record submitted data without shader execution or GPU validation.

local render = {}

export type FontSpec =
  { read kind: 'default' }
  | { read kind: 'file', read file: string, read size: number, read spread: number? }
export type Font = {
  spec: FontSpec,
  released: boolean,
  release: (Font) -> (),
  getHeight: (Font) -> number,
  getLineSpacing: (Font) -> number,
  getAscent: (Font) -> number,
  setPixelDensity: (Font, number?) -> (),
  getWidth: (Font, string) -> number,
  getLines: (Font, string, number?) -> { string },
}
export type VertexFormat = { { string | number } }
export type MeshFlags = { read storage: string?, read mode: string? }
export type Mesh = {
  capacity: number,
  format: VertexFormat?,
  flags: MeshFlags?,
  attributeCount: number,
  positionOffset: number?,
  vertices: { { number } },
  indices: { number },
  released: boolean,
  setVertices: (Mesh, { { number } }) -> (),
  setIndices: (Mesh, { number }) -> (),
  release: (Mesh) -> (),
}
export type Shader = { vertex: string, fragment: string, released: boolean, release: (Shader) -> () }
-- Recorded graphics calls retain the different overloads accepted at the LÖVR boundary.
export type TextureToken = { read name: string?, read getDimensions: ((TextureToken) -> (number, number))? }
export type Argument =
  nil
  | boolean
  | number
  | string
  | vector
  | Mat4
  | quaternion
  | Texture
  | Material
  | Font
  | Mesh
  | Shader
  | TextureToken
  | { number }
  | { { number } }
  | { vector }
  | { x: number, y: number, z: number }
export type Arguments = { [number]: Argument, n: number }
export type State = { [string]: Arguments }
export type Stacks = { state: { State }, transform: { Mat4 } }
export type Checkpoint = { state: State, transform: Mat4, stacks: Stacks }
export type Call = { [number]: Argument, n: number, state: State, transform: Mat4, draw: boolean?, points: { vector }? }
export type Box = { read x: number, read y: number, read width: number, read height: number, read tolerance: number? }
export type Pass = {
  getFont: (Pass) -> Font,
  send: (Pass, string, ...Argument) -> (),
  setClear: (Pass, ...Argument) -> (),
  setColor: (Pass, ...Argument) -> (),
  setFont: (Pass, Font) -> (),
  setDepthTest: (Pass, ...Argument) -> (),
  setDepthWrite: (Pass, boolean) -> (),
  setShader: (Pass, (Shader | string)?) -> (),
  setMaterial: (Pass, Argument) -> (),
  setBlendMode: (Pass, ...Argument) -> (),
  setCullMode: (Pass, ...Argument) -> (),
  setScissor: (Pass, ...Argument) -> (),
  push: (Pass, ...Argument) -> (),
  pop: (Pass, ...Argument) -> (),
  origin: (Pass) -> (),
  transform: (Pass, ...Argument) -> (),
  translate: (Pass, ...Argument) -> (),
  rotate: (Pass, ...Argument) -> (),
  scale: (Pass, ...Argument) -> (),
  plane: (Pass, ...Argument) -> (),
  roundrect: (Pass, ...Argument) -> (),
  text: (Pass, ...Argument) -> (),
  line: (Pass, ...Argument) -> (),
  sphere: (Pass, ...Argument) -> (),
  draw: (Pass, ...Argument) -> (),
}
export type Recorder = {
  calls: { Call },
  _sink: () -> { Call },
  font: Font,
  pass: Pass,
  fontMeasurements: { { font: Font, method: string, text: string? } },
  meshAcquisitions: { Mesh },
  shaderAcquisitions: { Shader },
  meshReleases: { Mesh },
  shaderReleases: { Shader },
  meshFailure: string?,
  shaderFailure: string?,
  _state: State,
  _transform: Mat4,
  _stacks: Stacks,
  _initial: Checkpoint,
  newFont: (Recorder, string, number, number) -> Font,
  newMesh: (Recorder, number | VertexFormat, ({ { number } } | number | MeshFlags)?, MeshFlags?) -> Mesh,
  newShader: (Recorder, string, string) -> Shader,
  newTexture: (Recorder, any, any?) -> Texture,
  textureAcquisitions: { Texture },
  assertMeshesReleased: (Recorder) -> (),
  assertResourcesReleased: (Recorder) -> (),
  within: <R...>(Recorder, Box, (Pass) -> R...) -> R...,
  checkpoint: (Recorder) -> Checkpoint,
  assertRestored: (Recorder, Checkpoint?) -> (),
}

local Recorder = {}
Recorder.__index = Recorder

type FileFontSpec = { read kind: 'file', read file: string, read size: number, read spread: number? }
local newFont: (FileFontSpec?, Recorder?) -> Font
local newPass: (Recorder) -> Pass
local copyState: (State) -> State
local copyStacks: (Stacks) -> Stacks
local sameMatrix: (Mat4, Mat4) -> boolean
local sameState: (State, State) -> boolean
local geometry: (string, Arguments, Mat4, Font) -> { vector }?
local readTransform: (Arguments, number, number) -> (Mat4, number)
local readVector: (Arguments, number) -> (number, number, number, number)
local SETTERS = {
  'setClear',
  'setColor',
  'setFont',
  'setDepthTest',
  'setDepthWrite',
  'setShader',
  'setMaterial',
  'setBlendMode',
  'setCullMode',
  'setScissor',
}
local DRAW_METHODS = { 'plane', 'roundrect', 'text', 'line', 'sphere', 'draw' }

function render.new(calls: ({ Call } | () -> { Call })?): Recorder
  calls = calls or {}
  local sink = if type(calls) == 'function'
    then calls
    else function(): { Call }
      return calls
    end
  local self = setmetatable({
    calls = sink(),
    _sink = sink,
    font = newFont(),
    fontMeasurements = {},
    meshAcquisitions = {},
    shaderAcquisitions = {},
    textureAcquisitions = {},
    meshReleases = {},
    shaderReleases = {},
    _state = {},
    _transform = lovr.math.newMat4(),
    _stacks = { state = {}, transform = {} },
  }, Recorder)
  self.pass = newPass(self)
  self._initial = self:checkpoint()
  return self
end

function Recorder.newFont(self: Recorder, file: string, size: number, spread: number): Font
  local spec = table.freeze { kind = 'file', file = file, size = size, spread = spread }
  return newFont(spec, self)
end

function Recorder.newMesh(
  self: Recorder,
  formatOrCount: number | VertexFormat,
  verticesOrCount: ({ { number } } | number | MeshFlags)?,
  flags: MeshFlags?
): Mesh
  if self.meshFailure then
    local message = self.meshFailure
    self.meshFailure = nil
    error(message, 0)
  end
  -- `newMesh(vertices, flags)` passes vertices in the default format where a format would otherwise be.
  local initial: { { number } }? = nil
  if type(formatOrCount) == 'table' then
    local first = (formatOrCount :: { any })[1]
    if type(first) == 'table' and type(first[1]) == 'number' then
      initial = formatOrCount :: any
      flags = verticesOrCount :: MeshFlags?
      formatOrCount, verticesOrCount = #formatOrCount, nil
    end
  end
  local custom = type(formatOrCount) == 'table'
  if not custom and type(verticesOrCount) == 'table' then
    flags = verticesOrCount
  end
  local vertices = if custom and type(verticesOrCount) == 'table' then verticesOrCount else nil
  local count = if custom then (if vertices then #vertices else verticesOrCount) else formatOrCount
  assert(type(count) == 'number' and count >= 0 and count % 1 == 0, 'render recorder: invalid mesh capacity')
  local attributeCount, positionOffset = 8, 1
  local format: VertexFormat? = nil
  if custom then
    format = {}
    attributeCount, positionOffset = 0, nil
    for _, attribute in formatOrCount do
      local dataType = attribute[2]
      local components = if type(attribute[3]) == 'number'
        then attribute[3]
        else tonumber(tostring(dataType):match 'x(%d+)$') or 1
      assert(components > 0 and components % 1 == 0, 'render recorder: invalid mesh attribute')
      if attribute[1] == 'VertexPosition' and components >= 3 then
        positionOffset = attributeCount + 1
      end
      attributeCount += components
      format[#format + 1] = table.freeze(table.clone(attribute))
    end
    assert(attributeCount > 0, 'render recorder: empty mesh format')
    table.freeze(format)
  end
  local recorder = self
  local mesh: Mesh = {
    capacity = count,
    format = format,
    flags = if flags then table.freeze(table.clone(flags)) else nil,
    attributeCount = attributeCount,
    positionOffset = positionOffset,
    vertices = if initial then table.clone(initial) else {},
    indices = {},
    released = false,
  }
  function mesh.setVertices(self: Mesh, vertices: { { number } })
    assert(not self.released, 'render recorder: released mesh updated')
    assert(#vertices <= self.capacity, 'render recorder: mesh vertex capacity exceeded')
    self.vertices = {}
    for _, vertex in vertices do
      assert(#vertex == self.attributeCount, 'render recorder: mesh attributes do not match the format')
      for _, value in vertex do
        assert(
          type(value) == 'number' and value == value and math.abs(value) < math.huge,
          'render recorder: invalid vertex'
        )
      end
      self.vertices[#self.vertices + 1] = table.clone(vertex)
    end
  end
  function mesh.setIndices(self: Mesh, indices: { number })
    assert(not self.released, 'render recorder: released mesh updated')
    self.indices = table.clone(indices)
    for _, index in indices do
      assert(index % 1 == 0 and index > 0 and index <= #self.vertices, 'render recorder: invalid vertex index')
    end
  end
  function mesh.release(self: Mesh)
    assert(not self.released, 'render recorder: mesh released twice')
    self.released = true
    recorder.meshReleases[#recorder.meshReleases + 1] = self
  end
  if vertices then
    mesh:setVertices(vertices)
  end
  self.meshAcquisitions[#self.meshAcquisitions + 1] = mesh
  return mesh
end

function Recorder.newShader(self: Recorder, vertex: string, fragment: string): Shader
  if self.shaderFailure then
    local message = self.shaderFailure
    self.shaderFailure = nil
    error(message, 0)
  end
  local recorder = self
  local shader = { vertex = vertex, fragment = fragment, released = false }
  function shader.release(self: Shader)
    assert(not self.released, 'render recorder: shader released twice')
    self.released = true
    recorder.shaderReleases[#recorder.shaderReleases + 1] = self
  end
  self.shaderAcquisitions[#self.shaderAcquisitions + 1] = shader
  return shader
end

-- A texture records the images uploaded to it, so a test can tell how often its pixels changed.
export type Texture = {
  released: boolean,
  uploads: number,
  setPixels: (Texture, any) -> (),
  release: (Texture) -> (),
}

function Recorder.newTexture(self: Recorder, _source: any, _options: any?): Texture
  local texture: Texture = {
    released = false,
    uploads = 1,
    setPixels = function(texture: Texture, _image: any): ()
      assert(not texture.released, 'render recorder: pixels set on a released texture')
      texture.uploads += 1
    end,
    release = function(texture: Texture): ()
      assert(not texture.released, 'render recorder: texture released twice')
      texture.released = true
    end,
  }
  self.textureAcquisitions[#self.textureAcquisitions + 1] = texture
  return texture
end

function Recorder.assertMeshesReleased(self: Recorder)
  for _, mesh in self.meshAcquisitions do
    assert(mesh.released, 'render recorder: leaked mesh')
  end
end

function Recorder.assertResourcesReleased(self: Recorder)
  self:assertMeshesReleased()
  for _, shader in self.shaderAcquisitions do
    assert(shader.released, 'render recorder: leaked shader')
  end
  for _, texture in self.textureAcquisitions do
    assert(texture.released, 'render recorder: leaked texture')
  end
end

-- The box is in the coordinates of the transform current when within is called.
function Recorder.within<R...>(self: Recorder, box: Box, callback: (Pass) -> R...): R...
  self.calls = self._sink()
  local first, frame = #self.calls + 1, lovr.math.newMat4(self._transform)
  local results = table.pack(pcall(callback, self.pass))
  if not results[1] then
    error(results[2], 0)
  end
  self.calls = self._sink()
  local tolerance = box.tolerance or 0.001
  local inverse = frame:invert()
  for index = first, #self.calls do
    local call = self.calls[index]
    if call.draw then
      assert(call.points, 'render recorder: bounds: unmeasured ' .. call[1] .. ' at call ' .. index)
      for _, point in call.points do
        local x, y, z = inverse:mul(point.x, point.y, point.z)
        assert(
          math.abs(x) < math.huge and math.abs(y) < math.huge and math.abs(z) < math.huge,
          'render recorder: bounds: non-finite geometry at call ' .. index
        )
        assert(
          x >= box.x - tolerance
            and x <= box.x + box.width + tolerance
            and y >= box.y - tolerance
            and y <= box.y + box.height + tolerance,
          string.format(
            'render recorder: bounds: %s at call %d has point (%g, %g) outside the box',
            call[1],
            index,
            x,
            y
          )
        )
      end
    end
  end
  return table.unpack(results, 2, results.n)
end

function Recorder.checkpoint(self: Recorder): Checkpoint
  return {
    state = copyState(self._state),
    transform = lovr.math.newMat4(self._transform),
    stacks = copyStacks(self._stacks),
  }
end

function Recorder.assertRestored(self: Recorder, checkpoint: Checkpoint?)
  local wanted = checkpoint or self._initial
  for _, kind in { 'state', 'transform' } do
    local actual, saved = self._stacks[kind], wanted.stacks[kind]
    assert(
      #actual == #saved,
      string.format('render recorder: restoration: %s stack depth is %d, expected %d', kind, #actual, #saved)
    )
    for index, entry in actual do
      local equal = if kind == 'state' then sameState(entry, saved[index]) else sameMatrix(entry, saved[index])
      assert(equal, 'render recorder: restoration: caller-owned ' .. kind .. ' stack entry changed')
    end
  end
  assert(sameMatrix(self._transform, wanted.transform), 'render recorder: restoration: transform changed')
  assert(sameState(self._state, wanted.state), 'render recorder: restoration: drawing state changed')
end

newFont = function(spec: FileFontSpec?, recorder: Recorder?): Font
  local font = { spec = spec or table.freeze { kind = 'default' }, released = false }
  local advance = if spec then 0.7 + spec.size / 1000 + (spec.spread or 0) / 10000 else 0.5
  local height = if spec then 1.2 else 1
  local function live(method: string, text: string?)
    assert(not font.released, 'render recorder: released font used for ' .. method)
    if recorder then
      recorder.fontMeasurements[#recorder.fontMeasurements + 1] = { font = font, method = method, text = text }
    end
  end
  function font.release(self: Font)
    assert(spec, 'render recorder: default font must not be released')
    assert(not self.released, 'render recorder: font released twice')
    self.released = true
  end
  function font.getHeight(self: Font): number
    live 'getHeight'
    return height
  end
  function font.getLineSpacing(self: Font): number
    live 'getLineSpacing'
    return if spec then 1.1 else 1
  end
  function font.getAscent(self: Font): number
    live 'getAscent'
    return height * 0.8
  end
  function font.setPixelDensity(self: Font, _density: number?)
    live 'setPixelDensity'
  end
  function font.getWidth(self: Font, text: string): number
    live('getWidth', text)
    local width = 0
    for line in (text .. '\n'):gmatch '(.-)\n' do
      local count = utf8.len(line)
      assert(count, 'render recorder: font: invalid UTF-8')
      width = math.max(width, count * advance)
    end
    return width
  end
  function font.getLines(self: Font, text: string, wrap: number?): { string }
    live('getLines', text)
    wrap = wrap or 0
    assert(wrap >= 0 and wrap < math.huge, 'render recorder: font: invalid wrap')
    local limit = if wrap == 0 then math.huge else math.max(1, math.floor(wrap / advance))
    local lines: { string } = {}
    for line in (text .. '\n'):gmatch '(.-)\n' do
      assert(utf8.len(line), 'render recorder: font: invalid UTF-8')
      local start, count = 1, 0
      for offset in utf8.codes(line) do
        if count == limit then
          lines[#lines + 1] = line:sub(start, offset - 1)
          start, count = offset, 0
        end
        count += 1
      end
      lines[#lines + 1] = line:sub(start)
    end
    return lines
  end
  return font
end

newPass = function(recorder: Recorder): Pass
  local pass = {}
  local function record(name: string, ...: Argument): Call
    recorder.calls = recorder._sink()
    local call: Call = table.pack(name, ...)
    for index = 2, call.n do
      if type(call[index]) == 'userdata' and call[index].type and call[index]:type() == 'Mat4' then
        call[index] = lovr.math.newMat4(call[index])
      end
    end
    call.state = copyState(recorder._state)
    call.transform = lovr.math.newMat4(recorder._transform)
    recorder.calls[#recorder.calls + 1] = call
    return call
  end
  for _, method in SETTERS do
    pass[method] = function(_: Pass, ...: Argument)
      record(method, ...)
      recorder._state[method] = table.pack(...)
    end
  end
  local function copyUniform(value: any): any
    if type(value) ~= 'table' or value.release then
      return value
    end
    local copy = {}
    for key, entry in value do
      copy[key] = copyUniform(entry)
    end
    return copy
  end
  function pass.send(self: Pass, name: string, ...: Argument)
    local call = record('send', name, ...)
    for index = 3, call.n do
      call[index] = copyUniform(call[index])
    end
  end
  function pass.getFont(self: Pass): Font
    local setting = recorder._state.setFont
    return setting and setting[1] or recorder.font
  end
  function pass.push(self: Pass, ...: Argument)
    local kind = (...) or 'transform'
    assert(recorder._stacks[kind], 'render recorder: push: unknown stack ' .. tostring(kind))
    record('push', ...)
    table.insert(
      recorder._stacks[kind],
      if kind == 'state' then copyState(recorder._state) else lovr.math.newMat4(recorder._transform)
    )
  end
  function pass.pop(self: Pass, ...: Argument)
    local kind = (...) or 'transform'
    record('pop', ...)
    local stack = recorder._stacks[kind]
    assert(stack, 'render recorder: pop: unknown stack ' .. tostring(kind))
    assert(#stack > 0, 'render recorder: pop: ' .. kind .. ' stack underflow')
    local saved = table.remove(stack)
    if kind == 'state' then
      recorder._state = saved
    else
      recorder._transform = saved
    end
  end
  for _, method in { 'translate', 'rotate', 'scale' } do
    pass[method] = function(_: Pass, ...: Argument)
      record(method, ...)
      recorder._transform[method](recorder._transform, ...)
    end
  end
  function pass.origin(self: Pass)
    record 'origin'
    recorder._transform:identity()
  end
  function pass.transform(self: Pass, ...: Argument)
    record('transform', ...)
    local args = table.pack(...)
    local matrix: Mat4
    if args.n == 7 then
      matrix = lovr.math.newMat4():translate(args[1], args[2], args[3]):rotate(args[4], args[5], args[6], args[7])
    else
      matrix = readTransform(args, 1, 3)
    end
    recorder._transform:mul(matrix)
  end
  for _, method in DRAW_METHODS do
    pass[method] = function(_: Pass, ...: Argument)
      local call = record(method, ...)
      call.draw = true
      call.points = geometry(method, table.pack(...), call.transform, pass:getFont())
    end
  end
  return pass
end

copyState = function(state: State): State
  local result: State = {}
  for key, value in state do
    result[key] = table.clone(value)
  end
  return result
end

copyStacks = function(stacks: Stacks): Stacks
  local result: Stacks = { state = {}, transform = {} }
  for kind, entries in stacks do
    for index, entry in entries do
      result[kind][index] = if kind == 'state' then copyState(entry) else lovr.math.newMat4(entry)
    end
  end
  return result
end

sameMatrix = function(a: Mat4, b: Mat4): boolean
  local left, right = { a:unpack(true) }, { b:unpack(true) }
  for index, value in left do
    if not (math.abs(value - right[index]) <= 0.00001) then
      return false
    end
  end
  return true
end

sameState = function(a: State, b: State): boolean
  for key, value in a do
    local other = b[key]
    if not other or value.n ~= other.n then
      return false
    end
    for index = 1, value.n do
      if value[index] ~= other[index] then
        return false
      end
    end
  end
  for key in b do
    if not a[key] then
      return false
    end
  end
  return true
end

geometry = function(method: string, args: Arguments, transform: Mat4, font: Font): { vector }?
  local points: { vector } = {}
  local function point(matrix: Mat4, x: number, y: number, z: number?)
    local px, py, pz = matrix:mul(x, y, z or 0)
    points[#points + 1] = vector.pack(px, py, pz)
  end
  local function rectangle(matrix: Mat4, x: number, y: number, width: number, height: number, z: number?)
    point(matrix, x, y, z)
    point(matrix, x + width, y, z)
    point(matrix, x + width, y + height, z)
    point(matrix, x, y + height, z)
  end
  if method == 'plane' or method == 'roundrect' then
    local localTransform, index = readTransform(args, 1, if method == 'plane' then 2 else 3)
    local matrix = lovr.math.newMat4(transform):mul(localTransform)
    if method == 'plane' then
      local style = args[index]
      assert(style == nil or style == 'fill' or style == 'line', 'render recorder: plane: invalid style')
    end
    if method == 'roundrect' then
      rectangle(matrix, -0.5, -0.5, 1, 1, 0.5)
      rectangle(matrix, -0.5, -0.5, 1, 1, -0.5)
    else
      rectangle(matrix, -0.5, -0.5, 1, 1)
    end
  elseif method == 'text' then
    assert(type(args[1]) == 'string', 'render recorder: text: colored strings are not measured')
    local localTransform, index = readTransform(args, 2, 1)
    local matrix = lovr.math.newMat4(transform):mul(localTransform)
    local lines = font:getLines(args[1], args[index] or 0)
    local horizontal, vertical = args[index + 1] or 'center', args[index + 2] or 'middle'
    assert(
      horizontal == 'left' or horizontal == 'center' or horizontal == 'right',
      'render recorder: text: invalid alignment'
    )
    assert(
      vertical == 'top' or vertical == 'middle' or vertical == 'bottom',
      'render recorder: text: invalid alignment'
    )
    local height, leading = font:getHeight(), font:getHeight() * font:getLineSpacing()
    local total = height + math.max(0, #lines - 1) * leading
    local top = if vertical == 'top' then 0 elseif vertical == 'middle' then total / 2 else total
    for row, line in lines do
      if line ~= '' then
        local width = font:getWidth(line)
        local left = if horizontal == 'left' then 0 elseif horizontal == 'center' then -width / 2 else -width
        rectangle(matrix, left, top - (row - 1) * leading - height, width, height)
      end
    end
  elseif method == 'draw' then
    local mesh = args[1]
    if type(mesh) ~= 'table' or not mesh.vertices then
      return nil
    end
    assert(not mesh.released, 'render recorder: released mesh drawn')
    local localTransform = readTransform(args, 2, 3)
    local matrix = lovr.math.newMat4(transform):mul(localTransform)
    if not mesh.positionOffset then
      return nil
    end
    local offset = mesh.positionOffset
    local indices = mesh.indices
    if #indices == 0 then
      indices = {}
      for index in mesh.vertices do
        indices[#indices + 1] = index
      end
    end
    for _, index in indices do
      local vertex = mesh.vertices[index]
      point(matrix, vertex[offset], vertex[offset + 1], vertex[offset + 2])
    end
  elseif method == 'line' then
    local vertices = if args.n == 1 and type(args[1]) == 'table' then args[1] else args
    local count = vertices.n or #vertices
    local index = 1
    while index <= count do
      local x, y, z, nextIndex = readVector(vertices, index)
      point(transform, x, y, z)
      index = nextIndex
    end
  else
    return nil
  end
  return points
end

readTransform = function(args: Arguments, index: number, dimensions: number): (Mat4, number)
  local value = args[index]
  if value == nil then
    return lovr.math.newMat4(), index + 1
  elseif type(value) == 'userdata' then
    return lovr.math.newMat4(value), index + 1
  end
  local x, y, z, nextIndex = readVector(args, index)
  local matrix = lovr.math.newMat4():translate(x, y, z)
  index = nextIndex
  local sx, sy, sz = 1, 1, 1
  value = args[index]
  if type(value) == 'number' then
    sx, sy = value, if dimensions > 1 then args[index + 1] or value else value
    sz = if dimensions == 3 then args[index + 2] or value elseif dimensions == 1 then value else 1
    index += dimensions
  elseif value == nil then
    index += 1
  else
    sx, sy, sz, index = readVector(args, index)
  end
  value = args[index]
  if type(value) == 'number' then
    matrix:rotate(value, args[index + 1] or 0, args[index + 2] or 1, args[index + 3] or 0)
    index += 4
  else
    if value ~= nil then
      matrix:rotate(value)
    end
    index += 1
  end
  return matrix:scale(sx, sy, sz), index
end

readVector = function(args: Arguments, index: number): (number, number, number, number)
  local value = args[index]
  if type(value) == 'number' then
    return value, args[index + 1] or value, args[index + 2] or value, index + 3
  elseif type(value) == 'vector' then
    return value.x, value.y, value.z, index + 1
  elseif type(value) == 'table' then
    return value[1] or value.x, value[2] or value.y, value[3] or value.z, index + 1
  end
  error('render recorder: expected a number, table, or vector', 0)
end

return render
