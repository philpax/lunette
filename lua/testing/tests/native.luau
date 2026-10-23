local testing = require '@testing'
local upload = require '@lunette-plugins/ui/host/private/rendering/upload'
local expect = testing.expect
local test = testing.suite()

local function values(count: number): { number }
  local data = {}
  for index = 1, count do
    data[index] = index
  end
  return data
end

local function expectRange(sent: { { number } }, first: number, count: number): ()
  expect.equal(#sent, 1, 'the uniform block contains one flat array')
  for index = 1, count do
    expect.equal(sent[1][index], first + index - 1, `scalar {index}`)
  end
end

test('native graphics exposes buffer uploads through the recorder and its leak check', function()
  local fake = testing.native()
  local buffer = lovr.graphics.newBuffer('vec4', 1)
  buffer:setData({ 1, 2, 3, 4 }, 1, 1, 1)
  fake.events.pass:send('Instances', buffer, 0, 16)
  expectRange(fake.events.draw[1][3], 1, 4)
  expect.equal(fake.events.render.bufferAcquisitions[1], buffer)
  expect.raises(fake.assertResourcesReleased, 'leaked buffer')
  buffer:release()
  expect.equal(fake.events.render.bufferReleases[1], buffer)
  fake.assertResourcesReleased()
end)

test('UI uploads preserve padded batch ranges and do not copy inactive source tails', function()
  local fake = testing.native()
  local recorder = fake.events.render
  local mesh = lovr.graphics.newMesh(0)
  local layout = upload.layout('Instances', 1, 3)
  expect.truthy(lovr.graphics.getLimits().uniformBufferAlign >= 16)
  expect.truthy(layout.stride > layout.bytes, 'the fixture exercises alignment padding')
  expect.equal(layout.stride % lovr.graphics.getLimits().uniformBufferAlign, 0)
  local data = values(20)
  data[21], data[22] = 0 / 0, math.huge
  upload.draw(layout, fake.events.pass, mesh, lovr.math.newMat4(), data, 5)
  expect.equal(#fake.events.draw, 4, 'each batch sends and draws once')
  local first, second = fake.events.draw[1], fake.events.draw[3]
  expect.equal(first[1], 'send')
  expect.equal(first[2], 'Instances')
  expect.equal(first[4], 0)
  expect.equal(first[5], layout.bytes)
  expect.equal(#first[3][1], 12, 'the binding includes the shader array capacity')
  expectRange(first[3], 1, 12)
  expect.equal(second[4], layout.stride, 'the next binding starts after the padding')
  expect.equal(second[5], layout.bytes)
  expectRange(second[3], 13, 8)
  for index = 9, 12 do
    expect.equal(second[3][1][index], 0, 'the unused final instance is zero-initialized')
  end
  expect.equal(fake.events.draw[2][4], 3, 'the first batch instance count')
  expect.equal(fake.events.draw[4][4], 2, 'the final batch instance count')
  expect.equal(#recorder.bufferAcquisitions, 1)
  expect.equal(#recorder.bufferReleases, 1, 'the upload releases after recording')
  expect.truthy(recorder.bufferAcquisitions[1].released)
  data[1] = 99
  upload.draw(layout, fake.events.pass, mesh, lovr.math.newMat4(), data, 1)
  expect.equal(first[3][1][1], 1, 'the earlier pass snapshot remains unchanged')
  local later = fake.events.draw[5][3] :: { { number } }
  expect.equal(later[1][1], 99)
  for index = 5, 12 do
    expect.equal(later[1][index], 0, 'inactive source values do not reach a later draw')
  end
  expect.equal(#recorder.bufferReleases, 2)
  mesh:release()
  fake.assertResourcesReleased()
end)

test('UI uploads handle contiguous batches and empty draws without extra acquisitions', function()
  local fake = testing.native()
  local mesh = lovr.graphics.newMesh(0)
  local batch = lovr.graphics.getLimits().uniformBufferAlign / 16
  local layout = upload.layout('Instances', 1, batch)
  expect.equal(layout.stride, layout.bytes)
  upload.draw(layout, fake.events.pass, mesh, lovr.math.newMat4(), {}, 0)
  expect.equal(#fake.events.render.bufferAcquisitions, 0)
  expect.equal(#fake.events.draw, 0)
  upload.draw(layout, fake.events.pass, mesh, lovr.math.newMat4(), values((batch + 1) * 4), batch + 1)
  expectRange(fake.events.draw[1][3], 1, batch * 4)
  expectRange(fake.events.draw[3][3], batch * 4 + 1, 4)
  expect.equal(#fake.events.render.bufferReleases, 1)
  mesh:release()
  fake.assertResourcesReleased()
end)

test('UI uploads release buffers when a write or a pass recording fails', function()
  local fake = testing.native()
  local mesh = lovr.graphics.newMesh(0)
  local layout = upload.layout('Instances', 1, 1)
  expect.raises(function()
    upload.draw(layout, fake.events.pass, mesh, lovr.math.newMat4(), { 1, 2, 3, math.huge }, 1)
  end, 'buffer value')
  expect.equal(#fake.events.render.bufferReleases, 1, 'a rejected write releases its acquisition')
  local pass = {
    send = function()
      error('test: rejected send', 0)
    end,
  }
  expect.raises(function()
    upload.draw(layout, pass, mesh, lovr.math.newMat4(), { 1, 2, 3, 4 }, 1)
  end, 'rejected send')
  expect.equal(#fake.events.render.bufferAcquisitions, 2)
  expect.equal(#fake.events.render.bufferReleases, 2)
  mesh:release()
  fake.assertResourcesReleased()
end)

return test
