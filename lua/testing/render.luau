-- Records development-only drawing with real LÖVR transforms and deterministic codepoint font metrics.
-- new(calls?) returns { pass, font, calls }; calls retain { method, ... } plus snapshot metadata.
-- Supply a function returning events.draw when callers replace that table between frames.
-- within(box, callback) checks emitted geometry in the entry transform's coordinates, not framebuffer pixels.
-- checkpoint()/assertRestored(checkpoint?) diagnose state and stack leaks without repairing or hiding errors.
-- Text bounds are metric boxes, not rasterized glyph ink. No shaping or grapheme segmentation is simulated.

local render = {}
local Recorder = {}
Recorder.__index = Recorder

local newFont, newPass, copyState, copyStacks, sameMatrix, sameState, geometry, readTransform, readVector
local SETTERS = {
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

function render.new(calls)
  calls = calls or {}
  local sink = if type(calls) == 'function'
    then calls
    else function()
      return calls
    end
  local self = setmetatable({
    calls = sink(),
    _sink = sink,
    font = newFont(),
    _state = {},
    _transform = lovr.math.newMat4(),
    _stacks = { state = {}, transform = {} },
  }, Recorder)
  self.pass = newPass(self)
  self._initial = self:checkpoint()
  return self
end

function Recorder:within(box, callback)
  self.calls = self._sink()
  local first, frame = #self.calls + 1, lovr.math.newMat4(self._transform)
  local results = table.pack(pcall(callback, self.pass))
  if not results[1] then
    error(results[2], 0)
  end
  self:assertBounds(box, first, #self.calls, frame)
  return table.unpack(results, 2, results.n)
end

-- A frame maps the assertion's local coordinates to world coordinates; it defaults to the identity.
-- Scissors are captured but never used to excuse logical bounds violations on a posed XR surface.
function Recorder:assertBounds(box, first, last, frame)
  self.calls = self._sink()
  for _, field in { 'x', 'y', 'width', 'height' } do
    assert(
      type(box[field]) == 'number' and math.abs(box[field]) < math.huge,
      'render recorder: bounds: invalid ' .. field
    )
  end
  assert(box.width >= 0 and box.height >= 0, 'render recorder: bounds: negative size')
  local tolerance = box.tolerance or 0.001
  assert(tolerance >= 0 and tolerance < math.huge, 'render recorder: bounds: invalid tolerance')
  local basis = lovr.math.newMat4(frame)
  local inverse = lovr.math.newMat4(basis):invert()
  assert(
    sameMatrix(lovr.math.newMat4(basis):mul(inverse), lovr.math.newMat4()),
    'render recorder: bounds: frame is not invertible'
  )
  for index = first or 1, last or #self.calls do
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
end

function Recorder:checkpoint()
  return {
    state = copyState(self._state),
    transform = lovr.math.newMat4(self._transform),
    stacks = copyStacks(self._stacks),
  }
end

function Recorder:assertRestored(checkpoint)
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
  assert(sameState(self._state, wanted.state), 'render recorder: restoration: drawing state or scissor changed')
end

newFont = function()
  local font = {}
  function font:getHeight()
    return 1
  end
  function font:getLineSpacing()
    return 1
  end
  function font:getWidth(text)
    local width = 0
    for line in (text .. '\n'):gmatch '(.-)\n' do
      local count = utf8.len(line)
      assert(count, 'render recorder: font: invalid UTF-8')
      width = math.max(width, count * 0.5)
    end
    return width
  end
  function font:getLines(text, wrap)
    wrap = wrap or 0
    assert(wrap >= 0 and wrap < math.huge, 'render recorder: font: invalid wrap')
    local limit = if wrap == 0 then math.huge else math.max(1, math.floor(wrap * 2))
    local lines = {}
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

newPass = function(recorder)
  local pass = {}
  local function record(name, ...)
    recorder.calls = recorder._sink()
    local call = table.pack(name, ...)
    for index = 2, call.n do
      if type(call[index]) == 'userdata' and call[index].type and call[index]:type() == 'Mat4' then
        call[index] = lovr.math.newMat4(call[index])
      end
    end
    call.state = copyState(recorder._state)
    call.transform = lovr.math.newMat4(recorder._transform)
    call.scissor = if call.state.setScissor and call.state.setScissor[1] ~= nil
      then table.clone(call.state.setScissor)
      else nil
    recorder.calls[#recorder.calls + 1] = call
    return call
  end
  for _, method in SETTERS do
    pass[method] = function(_, ...)
      record(method, ...)
      local args = table.pack(...)
      if method == 'setScissor' and args[1] ~= nil then
        args[1], args[2] = math.max(args[1], 0), math.max(args[2], 0)
      end
      recorder._state[method] = args
    end
  end
  function pass:getFont()
    local setting = recorder._state.setFont
    return setting and setting[1] or recorder.font
  end
  function pass:push(...)
    local kind = (...) or 'transform'
    assert(recorder._stacks[kind], 'render recorder: push: unknown stack ' .. tostring(kind))
    record('push', ...)
    table.insert(
      recorder._stacks[kind],
      if kind == 'state' then copyState(recorder._state) else lovr.math.newMat4(recorder._transform)
    )
  end
  function pass:pop(...)
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
  function pass:origin()
    record 'origin'
    recorder._transform:identity()
  end
  for _, method in { 'translate', 'rotate', 'scale' } do
    pass[method] = function(_, ...)
      record(method, ...)
      recorder._transform[method](recorder._transform, ...)
    end
  end
  function pass:transform(...)
    record('transform', ...)
    local args = table.pack(...)
    local matrix
    if args.n == 7 then
      matrix = lovr.math.newMat4():translate(args[1], args[2], args[3]):rotate(args[4], args[5], args[6], args[7])
    else
      matrix = readTransform(args, 1, 3)
    end
    recorder._transform:mul(matrix)
  end
  for _, method in DRAW_METHODS do
    pass[method] = function(_, ...)
      local call = record(method, ...)
      call.draw = true
      call.points = geometry(method, table.pack(...), call.transform, pass:getFont())
    end
  end
  return pass
end

copyState = function(state)
  local result = {}
  for key, value in state do
    result[key] = table.clone(value)
  end
  return result
end

copyStacks = function(stacks)
  local result = { state = {}, transform = {} }
  for kind, entries in stacks do
    for index, entry in entries do
      result[kind][index] = if kind == 'state' then copyState(entry) else lovr.math.newMat4(entry)
    end
  end
  return result
end

sameMatrix = function(a, b)
  local left, right = { a:unpack(true) }, { b:unpack(true) }
  for index, value in left do
    if not (math.abs(value - right[index]) <= 0.00001) then
      return false
    end
  end
  return true
end

sameState = function(a, b)
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

geometry = function(method, args, transform, font)
  local points = {}
  local function point(matrix, x, y, z)
    local px, py, pz = matrix:mul(x, y, z or 0)
    points[#points + 1] = vector.pack(px, py, pz)
  end
  local function rectangle(matrix, x, y, width, height, z)
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

readTransform = function(args, index, dimensions)
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

readVector = function(args, index)
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
