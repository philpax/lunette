-- Real LÖVR conversion of flat number tables into Buffer data, including the float fast path and its fallback.

local testing = require '@testing'
local expect = testing.expect
local test = testing.suite()

-- Rounds through a float32, as the Buffer stores each value.
local function f32(value: number): number
  local bytes = buffer.create(4)
  buffer.writef32(bytes, 0, value)
  return buffer.readf32(bytes, 0)
end

local function read(target: Buffer, floats: number): { number }
  local readback = target:newReadback()
  readback:wait()
  return { readback:getBlob():getF32(0, floats) }
end

local function same(actual: number, wanted: number, context: string): ()
  if wanted ~= wanted then
    expect.truthy(actual ~= actual, context)
  else
    expect.equal(actual, f32(wanted), context)
  end
end

test('flat vec4 data converts every value to float32', function()
  local target = lovr.graphics.newBuffer('vec4', 3)
  local data = { 1, 1 / 3, -0.1, 1e30, math.huge, -math.huge, 0 / 0, -0, 2 ^ 24 + 1, 5, 6, 7 }
  target:setData(data)
  local values = read(target, #data)
  for index, wanted in data do
    same(values[index], wanted, `value {index}`)
  end
  target:release()
end)

test('vec3 and float formats convert flat data with their own strides', function()
  local vectors = lovr.graphics.newBuffer('vec3', 2)
  vectors:setData { 1, 2, 3, 4, 5, 6 }
  local values = read(vectors, 6)
  for index = 1, 6 do
    same(values[index], index, `vec3 value {index}`)
  end
  vectors:release()
  local scalars = lovr.graphics.newBuffer('float', 3)
  scalars:setData { 0.5, 0.25, 0.125 }
  local floats = read(scalars, 3)
  for index, wanted in { 0.5, 0.25, 0.125 } do
    same(floats[index], wanted, `float value {index}`)
  end
  scalars:release()
end)

test('destination, source, and count select the copied elements', function()
  local target = lovr.graphics.newBuffer('vec4', 3)
  target:setData { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  target:setData({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, 2, 5, 1)
  local values = read(target, 12)
  for index, wanted in { 0, 0, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0 } do
    same(values[index], wanted, `value {index}`)
  end
  target:release()
end)

-- Reverse insertion can leave values in the hash part, which the array-part reader leaves to the general path.
test('a table filled in reverse converts like one filled in order', function()
  local data = {}
  for index = 12, 1, -1 do
    data[index] = index / 4
  end
  local target = lovr.graphics.newBuffer('vec4', 3)
  target:setData(data)
  local values = read(target, 12)
  for index = 1, 12 do
    same(values[index], index / 4, `value {index}`)
  end
  target:release()
end)

test('a string value is rejected rather than converted, wherever it falls', function()
  local target = lovr.graphics.newBuffer('vec4', 2)
  local leading = expect.raises(function()
    target:setData { '1', 2, 3, 4, 5, 6, 7, 8 }
  end)
  local inner = expect.raises(function()
    target:setData { 1, 2, 3, 4, 5, '6', 7, 8 }
  end)
  expect.truthy(leading:find('got string', 1, true) ~= nil, leading)
  expect.truthy(inner:find('got string', 1, true) ~= nil, inner)
  target:release()
end)

test('non-float formats keep converting through the general path', function()
  local target = lovr.graphics.newBuffer('int', 3)
  target:setData { 1.75, -2.25, 3 }
  local readback = target:newReadback()
  readback:wait()
  local first, second, third = readback:getBlob():getI32(0, 3)
  expect.equal(first, 1, 'truncated positive value')
  expect.equal(second, -2, 'truncated negative value')
  expect.equal(third, 3, 'integral value')
  target:release()
end)

return test
