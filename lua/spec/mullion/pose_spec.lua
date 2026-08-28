-- Covers lua/mullion/pose.lua.
--
-- The round-trip tests the module's encoding of a pose. The encoded string
-- goes into the native property store and a file on disk, and both outlive
-- the process that wrote them. A decoder that lost the last digit would move
-- every panel a little further from where the user put it at every reload.

local expect = require '@spec/expect'
local suite = require '@spec/suite'

local pose = require '@mullion/pose'

local spec = suite.new 'mullion.pose'

-- The comparison is exact. The encoding returns a 32-bit float unchanged, and
-- a near comparison would assert less.
local function expectSame(recovered, original, context)
  local wanted = { original:unpack(true) }
  local got = { recovered:unpack(true) }
  for index = 1, pose.ELEMENTS do
    expect.equal(got[index], wanted[index], context .. ', element ' .. index)
  end
end

spec('a translated pose round-trips exactly', function()
  local original = lovr.math.newMat4():translate(1.5, -0.25, -3)

  expectSame(pose.decode(pose.encode(original)), original, 'the recovered pose')
end)

spec('a rotated and scaled pose round-trips exactly', function()
  -- The encoding writes sixteen numbers because a decomposition into a
  -- position and an orientation would drop the rotation and scale.
  local original = lovr.math.newMat4():translate(0.1, 2, -1.25):rotate(0.7, 0, 1, 0):scale(2, 3, 1)

  expectSame(pose.decode(pose.encode(original)), original, 'the recovered pose')
end)

spec('the identity round-trips exactly', function()
  local original = lovr.math.newMat4()

  expectSame(pose.decode(pose.encode(original)), original, 'the recovered pose')
end)

spec('a decoded pose is a fresh matrix', function()
  local original = lovr.math.newMat4():translate(1, 2, 3)
  local recovered = pose.decode(pose.encode(original))

  original:translate(10, 10, 10)

  local x = recovered:getPosition()
  expect.near(x, 1, 1e-6, 'x')
end)

spec('an encoded pose is sixteen numbers', function()
  local written = pose.encode(lovr.math.newMat4())

  local count = 0
  for _ in written:gmatch '%S+' do
    count = count + 1
  end
  expect.equal(count, pose.ELEMENTS, 'the numbers written')
end)

spec('decoding anything that is not sixteen numbers answers nothing', function()
  expect.falsy(pose.decode 'nowhere', 'a word')
  expect.falsy(pose.decode '1 2 3', 'too few numbers')
  expect.falsy(pose.decode '', 'nothing at all')
  expect.falsy(pose.decode(nil), 'nil')
  expect.falsy(pose.decode(42), 'a number')

  local seventeen = {}
  for index = 1, pose.ELEMENTS + 1 do
    seventeen[index] = '1'
  end
  expect.falsy(pose.decode(table.concat(seventeen, ' ')), 'too many numbers')
end)

spec('decoding a pose with a number that is not finite answers nothing', function()
  local elements = {}
  for index = 1, pose.ELEMENTS do
    elements[index] = '1'
  end

  elements[3] = 'nan'
  expect.falsy(pose.decode(table.concat(elements, ' ')), 'a nan')

  elements[3] = 'inf'
  expect.falsy(pose.decode(table.concat(elements, ' ')), 'an infinity')

  elements[3] = '1e400'
  expect.falsy(pose.decode(table.concat(elements, ' ')), 'a number too large to hold')
end)

return spec
