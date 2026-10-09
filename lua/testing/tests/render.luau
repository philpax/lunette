local testing = require '@testing'
local render = require '../render'
local managerDraw = require '@lunette-plugins/desktop/manager/draw'
local view = require '@lunette-plugins/desktop/manager/view'
local panelDraw = require '@lunette-plugins/panels/draw'
local expect = testing.expect
local test = testing.suite()

local function fixture()
  local fake = testing.native()
  local recorder = render.new(fake.events.draw)
  fake.events.render, fake.events.pass = recorder, recorder.pass
  lovr.graphics.getDefaultFont = function()
    return recorder.font
  end
  return recorder, fake
end

local function lastDraw(recorder)
  for index = #recorder.calls, 1, -1 do
    if recorder.calls[index].draw then
      return recorder.calls[index]
    end
  end
  error 'no recorded draw'
end

local function managerStyle(recorder)
  local theme = require('@lunette-plugins/theme/presets').BASE
  local appearance = require '../ui-substitute/appearance'
  local visual = table.clone(appearance.global { theme = theme })
  visual.font = recorder.font
  return { theme = theme, visual = table.freeze(visual) }
end

local function managerOptions()
  return {
    width = 600,
    height = 400,
    sidebar = 200,
    details = { 'Inspect the graph', 'A bounded detail with more than one line' },
    rows = {},
    buttons = { { x = -10, y = 360, width = 150, height = 60, label = 'Toggle', enabled = true } },
    footer = 'Ready',
  }
end

test('measures codepoints deterministically without pretending to segment graphemes', function()
  local font = render.new().font
  expect.equal(font:getHeight(), 1)
  expect.equal(font:getLineSpacing(), 1)
  expect.equal(font:getWidth '', 0)
  expect.equal(font:getWidth 'abcd', 2)
  expect.equal(font:getWidth 'a\nabc', 1.5, 'multiline maximum')
  expect.equal(font:getWidth 'é界', 1, 'non-ASCII codepoints')
  expect.equal(font:getWidth('e' .. utf8.char(0x301)), 1, 'combining marks are codepoints, not graphemes')
  local lines = font:getLines('é界ab\n\nxy\n', 1)
  expect.equal(table.concat(lines, '|'), 'é界|ab||xy|')
  expect.equal(#font:getLines('', 1), 1)
  expect.equal(table.concat(font:getLines('abcd', 0), '|'), 'abcd', 'zero wrap disables wrapping')
  expect.equal(table.concat(font:getLines('界ab', 0.1), '|'), '界|a|b', 'narrow wrap still advances')
  expect.raises(function()
    font:getWidth(string.char(255))
  end, 'UTF%-8')
  expect.raises(function()
    font:getLines('text', -1)
  end, 'wrap')
end)

test('keeps legacy call positions, nil arguments, and independent constructor state', function()
  local calls = {}
  local recorder = render.new(calls)
  expect.equal(recorder.calls, calls)
  expect.equal(recorder.pass:getFont(), recorder.font)
  recorder.pass:setMaterial(nil)
  recorder.pass:setColor(0.2, 0.3, 0.4, 0.5)
  recorder.pass:plane(5, 5, 0, 4, 4)
  expect.equal(calls[1][1], 'setMaterial')
  expect.equal(calls[1].n, 2, 'explicit nil is retained')
  expect.equal(calls[1][2], nil)
  expect.equal(calls[3][1], 'plane')
  expect.equal(calls[3][2], 5)
  expect.equal(calls[3][5], 4)
  expect.equal(calls[3].state.setColor[1], 0.2)
  recorder.pass:setColor(1, 1, 1, 1)
  expect.equal(calls[3].state.setColor[1], 0.2, 'state snapshot does not change later')
  local other = render.new()
  expect.equal(#other.calls, 0)
  other:assertRestored()
end)

test('follows replaced native draw tables and accepts rounded face and hint matrix overloads', function()
  local events = { draw = {} }
  local recorder = render.new(function()
    return events.draw
  end)
  local first = events.draw
  recorder.pass:roundrect(lovr.math.mat4():scale(0.04, 0.04, 0.01), 0.002)
  expect.equal(first[1][1], 'roundrect')
  events.draw = {}
  local pose = lovr.math.mat4():translate(vector.pack(2, 3, -4)):scale(0.1)
  recorder.pass:text('hint', pose, 0, 'center', 'middle')
  expect.equal(#first, 1)
  expect.equal(#events.draw, 1)
  expect.equal(recorder.calls, events.draw)
  local x, y, z = events.draw[1][3]:getPosition()
  expect.near(x, 2, 0.00001)
  expect.near(y, 3, 0.00001)
  expect.near(z, -4, 0.00001)
  pose:identity()
  expect.near(events.draw[1][3]:getPosition(), 2, 0.00001, 'temporary matrix copied persistently')
  events.draw = {}
  recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
    pass:plane(5, 5, 0, 4, 4)
  end)
  expect.equal(#events.draw, 1)
end)

test('composes real Mat4 transforms and retains matrix arguments after mutation', function()
  local recorder = render.new()
  local pass = recorder.pass
  local pose = lovr.math.newMat4():translate(3, -2, 1):rotate(math.pi / 2, 0, 0, 1)
  local face = lovr.math.newMat4():translate(2, 1, 0):scale(4, 2, 1)
  pass:push()
  pass:transform(pose)
  pass:translate(vector.pack(1, 2, 3))
  pass:scale(2, -3, 1)
  pass:plane(face, 'fill', 1, 1)
  local call = lastDraw(recorder)
  local expected = lovr.math.newMat4(pose):translate(1, 2, 3):scale(2, -3, 1):mul(face)
  local x, y, z = expected:mul(-0.5, -0.5, 0)
  expect.near(call.points[1].x, x, 0.0001)
  expect.near(call.points[1].y, y, 0.0001)
  expect.near(call.points[1].z, z, 0.0001)
  face:identity()
  local savedX = call[2]:mul(0.5, 0, 0)
  expect.near(savedX, 4, 0.0001, 'persistent argument copy')
  pass:pop()
  recorder:assertRestored()
end)

test('supports scalar rotations, pose transforms, and y-down text bounds', function()
  local recorder = render.new()
  local pass = recorder.pass
  pass:push()
  pass:transform(10, 20, 0, math.pi / 2, 0, 0, 1)
  pass:plane(0, 0, 0, 4, 2, math.pi / 2, 0, 0, 1, 'fill', 1, 1)
  local call = lastDraw(recorder)
  expect.near(call.points[1].x, 12, 0.0001)
  expect.near(call.points[1].y, 21, 0.0001)
  pass:origin()
  recorder:within({ x = 0, y = 0, width = 100, height = 40 }, function(current)
    current:text('abcd', 5, 7, 0, 10, math.pi, 1, 0, 0, 0, 'left', 'top')
    current:text('ab\ncd', lovr.math.newMat4():translate(60, 20, 0):scale(10), 0, 'center', 'middle')
    current:roundrect(30, 20, 0, 10, 10, 1, 0, 0, 0, 0, 1, 8)
  end)
  pass:pop()
  recorder:assertRestored()
end)

test('tracks independent stacks, fonts, and framebuffer scissors without transforming the clip', function()
  local recorder = render.new()
  local pass = recorder.pass
  local alternate = render.new().font
  pass:push 'state'
  pass:setColor(0.1, 0.2, 0.3, 0.4)
  pass:setFont(alternate)
  pass:setScissor(-4, -2, 20, 30)
  pass:push 'transform'
  pass:translate(5, 6, 7)
  local caller = recorder:checkpoint()
  pass:push 'state'
  pass:setScissor()
  pass:setFont()
  expect.equal(pass:getFont(), recorder.font)
  pass:push 'transform'
  pass:scale(4)
  pass:pop 'state'
  expect.equal(pass:getFont(), alternate)
  pass:line(0, 0, 0, 1, 1, 0)
  local call = lastDraw(recorder)
  expect.equal(call.scissor[1], 0)
  expect.equal(call.scissor[2], 0)
  expect.equal(call.scissor[3], 20)
  expect.near(call.points[2].x, 9, 0.0001, 'state pop does not pop the transform')
  pass:pop 'transform'
  recorder:assertRestored(caller)
  pass:pop 'transform'
  pass:pop 'state'
  recorder:assertRestored()
end)

test('checks bounds in the entry frame, records lines, and does not let scissors hide overflow', function()
  local recorder = render.new()
  local pass = recorder.pass
  pass:transform(lovr.math.newMat4():translate(4, 2, -3):rotate(0.6, 0, 1, 0):scale(0.01, -0.01, 1))
  local box = { x = 0, y = 0, width = 10, height = 10 }
  local value, missing = recorder:within(box, function(current)
    current:plane(5, 5, 0, 4, 4)
    current:line { vector.pack(0, 0, 0), vector.pack(10, 10, 0) }
    current:line { 0, 10, 0, 10, 0, 0 }
    return 'result', nil
  end)
  expect.equal(value, 'result')
  expect.equal(missing, nil)
  local mesh = recorder:newMesh(3)
  mesh:setVertices { { 0, 0, 0, 0, 0, 1, 0, 0 }, { 11, 0, 0, 0, 0, 1, 1, 0 }, { 0, 10, 0, 0, 0, 1, 0, 1 } }
  mesh:setIndices { 1, 2, 3 }
  for _, method in { 'plane', 'text', 'line', 'draw' } do
    expect.raises(function()
      recorder:within(box, function(current)
        current:setScissor(0, 0, 1, 1)
        if method == 'plane' then
          current:plane(5, 5, 0, 20, 20)
        elseif method == 'text' then
          current:text('overflow', 9, 5, 0, 1, math.pi, 1, 0, 0, 0, 'left', 'top')
        elseif method == 'draw' then
          current:draw(mesh)
        else
          current:line(0, 0, 0, 11, 10, 0)
        end
      end)
    end, 'bounds: ' .. method)
  end
  mesh:release()
  recorder:assertMeshesReleased()
end)

test('measures every line vertex for separate and aggregate overloads', function()
  local vertices = { { 1, 2, 0 }, { 4, 5, 0 }, { 7, 8, 0 } }
  local named = { { x = 1, y = 2, z = 0 }, { x = 4, y = 5, z = 0 }, { x = 7, y = 8, z = 0 } }
  local vectors = { vector.pack(1, 2, 0), vector.pack(4, 5, 0), vector.pack(7, 8, 0) }
  local overloads = {
    vertices,
    named,
    vectors,
    { vertices },
    { named },
    { vectors },
    { { 1, 2, 0, 4, 5, 0, 7, 8, 0 } },
    { 1, 2, 0, 4, 5, 0, 7, 8, 0 },
  }
  for _, args in overloads do
    local recorder = render.new()
    recorder.pass:translate(10, 20, 0)
    recorder.pass:line(table.unpack(args))
    local call = lastDraw(recorder)
    expect.equal(#call.points, 3, 'all line vertices are measured')
    expect.equal(call[1], 'line')
    expect.equal(call[2], args[1], 'positional arguments are unchanged')
    for index, point in call.points do
      expect.near(point.x, vertices[index][1] + 10, 0.0001)
      expect.near(point.y, vertices[index][2] + 20, 0.0001)
    end
  end
  for _, first in { { 1, 1, 0 }, { x = 1, y = 1, z = 0 } } do
    local recorder = render.new()
    expect.raises(function()
      recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
        pass:line(first, { 11, 1, 0 })
      end)
    end, 'bounds: line', 'later separate table vertex must not disappear')
  end
end)

test('rejects plane dimensions after a Mat4 instead of silently ignoring them', function()
  local recorder = render.new()
  local pose = lovr.math.newMat4():translate(5, 5, 0):scale(4, 4, 1)
  expect.raises(function()
    recorder.pass:plane(pose, 20, 20)
  end, 'plane: invalid style')
  expect.raises(function()
    recorder.pass:plane(5, 5, 0, 4, 4, 0, 0, 1, 0, 20)
  end, 'plane: invalid style', 'scalar transform reaches the same style parser')
  recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
    pass:plane(pose)
    pass:plane(pose, nil, 2, 3)
    pass:plane(pose, 'fill', 2, 3)
    pass:plane(pose, 'line', 2, 3)
  end)
end)

test('includes front and back roundrect depth in rotated bounds', function()
  for _, axis in { { 0, 1, 0 }, { 1, 0, 0 } } do
    for _, matrixOverload in { false, true } do
      local recorder = render.new()
      expect.raises(function()
        recorder:within({ x = -1, y = -1, width = 2, height = 2 }, function(pass)
          if matrixOverload then
            pass:roundrect(lovr.math.newMat4():rotate(math.pi / 2, table.unpack(axis)):scale(1, 1, 4), 0.1)
          else
            pass:roundrect(0, 0, 0, 1, 1, 4, math.pi / 2, axis[1], axis[2], axis[3], 0.1)
          end
        end)
      end, 'bounds: roundrect', 'depth projects beyond the center-plane box')
      recorder:assertBounds { x = -2, y = -2, width = 4, height = 4 }
      local low, high = math.huge, -math.huge
      for _, point in lastDraw(recorder).points do
        local value = if axis[2] == 1 then point.x else point.y
        low, high = math.min(low, value), math.max(high, value)
      end
      expect.near(low, -2, 0.0001, 'back face extent')
      expect.near(high, 2, 0.0001, 'front face extent')
    end
  end
  local recorder = render.new()
  recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
    pass:roundrect(5, 5, 0, 4, 4, 0, 0, 0, 1, 0, 0.1)
    pass:plane(5, 5, 0, 4, 4)
  end)
  for _, call in recorder.calls do
    for _, point in call.points do
      expect.near(point.z, 0, 0.0001, 'zero-depth roundrect and plane stay flat')
    end
  end
end)

test('diagnoses stack underflow, leaks, changed state, and unmeasured or non-finite geometry', function()
  local recorder = render.new()
  local pass = recorder.pass
  expect.raises(function()
    pass:pop 'state'
  end, 'underflow')
  pass:push()
  expect.raises(function()
    recorder:assertRestored()
  end, 'restoration: transform stack depth')
  pass:pop()
  pass:translate(1, 0, 0)
  expect.raises(function()
    recorder:assertRestored()
  end, 'restoration: transform changed')
  pass:origin()
  pass:setScissor(0, 0, 5, 5)
  expect.raises(function()
    recorder:assertRestored()
  end, 'restoration: drawing state or scissor')
  expect.raises(function()
    recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(current)
      current:sphere(5, 5, 0, 1)
    end)
  end, 'bounds: unmeasured sphere')
  expect.raises(function()
    recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(current)
      current:line(0 / 0, 0, 0, 1, 1, 0)
    end)
  end, 'bounds: non%-finite')
  expect.raises(function()
    recorder:assertBounds { x = 0, y = 0, width = -1, height = 2 }
  end, 'bounds: negative')
  local singular = render.new()
  singular.pass:scale(0, 1, 1)
  expect.raises(function()
    singular:within({ x = 0, y = 0, width = 10, height = 10 }, function(current)
      current:plane(5, 5, 0, 4, 4)
    end)
  end, 'bounds: frame is not invertible')
end)

test('preserves callback errors and leaves restoration diagnostics explicit', function()
  local recorder = render.new()
  local failure = { reason = 'draw failure' }
  local ok, message = pcall(function()
    recorder:within({ x = 0, y = 0, width = 10, height = 10 }, function(pass)
      pass:push 'state'
      pass:plane(5, 5, 0, 40, 40)
      error(failure, 0)
    end)
  end)
  expect.equal(ok, false)
  expect.equal(message, failure, 'bounds checks do not replace the original error')
  expect.raises(function()
    recorder:assertRestored()
  end, 'restoration: state stack depth')
  recorder.pass:pop 'state'
  recorder:assertRestored()
end)

test('checks existing manager logical clipping through a real XR projection', function()
  local recorder = fixture()
  local pass = recorder.pass
  local state = view.new { x = 400, y = 400 }
  view.update(state, {
    nodes = { { id = 'node', name = 'A bounded node', state = 'active', enabled = true } },
    edges = {},
  })
  state.layout = { node = { x = -60, y = 50, width = 180, height = 60 } }
  state.camera = { x = 0, y = 0, zoom = 1 }
  pass:push 'state'
  pass:setShader 'caller shader'
  pass:setScissor(2, 3, 12, 14)
  pass:push 'transform'
  pass:transform(lovr.math.newMat4():translate(1, 2, -3):rotate(0.5, 0, 1, 0))
  pass:translate(-0.6, 0.4, 0.002)
  pass:scale(0.002, -0.002, 1)
  local caller = recorder:checkpoint()
  recorder:within({ x = 0, y = 0, width = 600, height = 400 }, function(current)
    managerDraw.render(current, state, managerOptions(), managerStyle(recorder))
  end)
  recorder:assertRestored(caller)
  expect.truthy(#recorder.calls > 20, 'real manager emits geometry and text')
  pass:pop 'transform'
  pass:pop 'state'
  recorder:assertRestored()
end)

for _, failure in { 'text', 'getLines', 'pop' } do
  test('diagnoses manager restoration after ' .. failure .. ' raises without hiding its error', function()
    local recorder = fixture()
    local pass = recorder.pass
    local state = view.new { x = 400, y = 400 }
    local caller = recorder:checkpoint()
    local target = if failure == 'getLines' then recorder.font else pass
    local original = target[failure]
    local problem = { operation = failure }
    target[failure] = function(self, ...)
      if failure == 'pop' then
        original(self, ...)
      end
      error(problem, 0)
    end
    local ok, message = pcall(managerDraw.render, pass, state, managerOptions(), managerStyle(recorder))
    target[failure] = original
    expect.equal(ok, false)
    expect.equal(message, problem)
    recorder:assertRestored(caller)
    managerDraw.render(pass, state, managerOptions(), managerStyle(recorder))
    recorder:assertRestored(caller)
  end)
end

test('exposes failed manager cleanup while preserving the original drawing error', function()
  local recorder = fixture()
  local pass = recorder.pass
  local originalText, originalPop = pass.text, pass.pop
  local drawError, restoreError = {}, {}
  local attempted = {}
  pass.text = function()
    error(drawError, 0)
  end
  pass.pop = function(self, kind)
    attempted[#attempted + 1] = kind
    if kind == 'transform' then
      error(restoreError, 0)
    end
    originalPop(self, kind)
  end
  local ok, message =
    pcall(managerDraw.render, pass, view.new { x = 400, y = 400 }, managerOptions(), managerStyle(recorder))
  expect.equal(ok, false)
  expect.equal(message, drawError)
  expect.equal(table.concat(attempted, ','), 'transform,state', 'both cleanup operations are attempted')
  expect.raises(function()
    recorder:assertRestored()
  end, 'restoration: transform stack depth')
  pass.text, pass.pop = originalText, originalPop
  pass:pop 'transform'
  recorder:assertRestored()
end)

test('measures existing flat panel content and chrome without a GPU or a new UI API', function()
  local recorder = fixture()
  local pose = lovr.math.newMat4():translate(3, 2, -4):rotate(0.8, 0, 1, 0)
  local target = {
    kind = 'window',
    source = {
      getTexture = function()
        return 'fixture texture'
      end,
      title = 'Panel',
    },
    pose = pose,
    width = 2,
    height = 1,
    curve = 0,
    highlighted = false,
  }
  local caller = recorder:checkpoint()
  panelDraw.content(target, recorder.pass, function()
    return nil
  end)
  recorder:assertRestored(caller)
  panelDraw.chrome(target, recorder.pass, {
    font = recorder.font,
    windowRadius = 0,
    monitorRadius = 0,
    borderColor = { 0.2, 0.3, 0.4, 1 },
    borderThickness = 0.02,
    borderDepth = 0.01,
    titleColor = { 1, 1, 1, 1 },
    titleMargin = 0.02,
    titleHeight = 0.08,
  }, recorder.font)
  recorder:assertBounds({ x = -1.02, y = -0.52, width = 2.04, height = 1.14 }, nil, nil, pose)
  expect.equal(recorder.calls[1][1], 'push')
  local face
  for _, call in recorder.calls do
    if call[1] == 'plane' then
      face = call
      break
    end
  end
  expect.equal(face.state.setMaterial[1], 'fixture texture')
  expect.equal(lastDraw(recorder)[1], 'text')
end)

return test
