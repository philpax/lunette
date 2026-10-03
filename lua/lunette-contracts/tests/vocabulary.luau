-- Covers lua/lunette-contracts/vocabulary.luau: its pose encoding, whose round trip must be exact because
-- the string outlives the process and a lossy decoder would drift panels at every reload.

local testing = require '@testing'
local expect = testing.expect

local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

-- The comparison is exact. The encoding returns a 32-bit float unchanged, and
-- a near comparison would assert less.
local function expectSame(recovered, original, context)
  local wanted = { original:unpack(true) }
  local got = { recovered:unpack(true) }
  for index = 1, vocabulary.POSE_ELEMENTS do
    expect.equal(got[index], wanted[index], context .. ', element ' .. index)
  end
end

test('a translated pose round-trips exactly', function()
  local original = lovr.math.newMat4():translate(1.5, -0.25, -3)

  expectSame(vocabulary.decodePose(vocabulary.encodePose(original)), original, 'the recovered pose')
end)

test('a rotated and scaled pose round-trips exactly', function()
  -- A decomposition into position and orientation would drop the scale.
  local original = lovr.math.newMat4():translate(0.1, 2, -1.25):rotate(0.7, 0, 1, 0):scale(2, 3, 1)

  expectSame(vocabulary.decodePose(vocabulary.encodePose(original)), original, 'the recovered pose')
end)

test('the identity round-trips exactly', function()
  local original = lovr.math.newMat4()

  expectSame(vocabulary.decodePose(vocabulary.encodePose(original)), original, 'the recovered pose')
end)

test('generated poses round-trip exactly', function()
  -- A property over many poses rather than a handful of examples: any
  -- rotation, any translation, and any positive scale decode to the matrix
  -- that was encoded. The generator is seeded, so a failure reproduces.
  local random = lovr.math.newRandomGenerator(20261001)
  for case = 1, 200 do
    local original = lovr.math
      .newMat4()
      :translate((random:random() - 0.5) * 200, (random:random() - 0.5) * 200, (random:random() - 0.5) * 200)
      :rotate(random:random() * 2 * math.pi, random:random() - 0.5, random:random() - 0.5, random:random() + 0.01)
      :scale(random:random() * 10 + 1e-3, random:random() * 10 + 1e-3, random:random() * 10 + 1e-3)

    expectSame(vocabulary.decodePose(vocabulary.encodePose(original)), original, 'generated pose ' .. case)
  end
end)

test('a decoded pose is a fresh matrix', function()
  local original = lovr.math.newMat4():translate(1, 2, 3)
  local recovered = vocabulary.decodePose(vocabulary.encodePose(original))

  original:translate(10, 10, 10)

  local x = recovered:getPosition()
  expect.near(x, 1, 1e-6, 'x')
end)

test('an encoded pose is sixteen numbers', function()
  local written = vocabulary.encodePose(lovr.math.newMat4())

  local count = 0
  for _ in written:gmatch '%S+' do
    count = count + 1
  end
  expect.equal(count, vocabulary.POSE_ELEMENTS, 'the numbers written')
end)

test('decoding anything that is not sixteen numbers answers nothing', function()
  expect.falsy(vocabulary.decodePose 'nowhere', 'a word')
  expect.falsy(vocabulary.decodePose '1 2 3', 'too few numbers')
  expect.falsy(vocabulary.decodePose '', 'nothing at all')
  expect.falsy(vocabulary.decodePose(nil), 'nil')
  expect.falsy(vocabulary.decodePose(42), 'a number')

  local seventeen = {}
  for index = 1, vocabulary.POSE_ELEMENTS + 1 do
    seventeen[index] = '1'
  end
  expect.falsy(vocabulary.decodePose(table.concat(seventeen, ' ')), 'too many numbers')
end)

test('decoding a pose with a number that is not finite answers nothing', function()
  local elements = {}
  for index = 1, vocabulary.POSE_ELEMENTS do
    elements[index] = '1'
  end

  elements[3] = 'nan'
  expect.falsy(vocabulary.decodePose(table.concat(elements, ' ')), 'a nan')

  elements[3] = 'inf'
  expect.falsy(vocabulary.decodePose(table.concat(elements, ' ')), 'an infinity')

  elements[3] = '1e400'
  expect.falsy(vocabulary.decodePose(table.concat(elements, ' ')), 'a number too large to hold')
end)

return test
