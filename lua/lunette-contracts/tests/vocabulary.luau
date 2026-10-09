-- Covers the pose encoding in lua/lunette-contracts/vocabulary.luau. The round trip must be exact because the string outlives the process.

local testing = require '@testing'
local expect = testing.expect

local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

-- The encoding returns a 32-bit float unchanged, so a near comparison would assert less.
local function expectSame(recovered, original, context)
  local wanted = { original:unpack(true) }
  local got = { recovered:unpack(true) }
  for index = 1, vocabulary.POSE_ELEMENTS do
    expect.equal(got[index], wanted[index], context .. ', element ' .. index)
  end
end

test('generated poses round-trip exactly', function()
  local identity = lovr.math.newMat4()
  expectSame(vocabulary.decodePose(vocabulary.encodePose(identity)), identity, 'the identity')
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

test('decoding anything that is not sixteen finite numbers answers nothing', function()
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

  local elements = {}
  for index = 1, vocabulary.POSE_ELEMENTS do
    elements[index] = '1'
  end
  for _, invalid in { 'nan', 'inf', '1e400' } do
    elements[3] = invalid
    expect.falsy(vocabulary.decodePose(table.concat(elements, ' ')), invalid)
  end
end)

return test
