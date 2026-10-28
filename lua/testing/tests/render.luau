local testing = require '@testing'
local render = require '@testing/render'
local native = require '@testing/native'
local expect = testing.expect
local test = testing.suite()

local function expectValues(actual: { number }, wanted: { number }): ()
  expect.equal(#actual, #wanted, 'the recorded scalar count')
  for index = 1, #wanted do
    expect.equal(actual[index], wanted[index], `scalar {index}`)
  end
end

test('a buffer send snapshots only its byte range in the table-uniform format', function()
  local recorder = render.new()
  local buffer = recorder:newBuffer('vec4', 4)
  local data = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }
  buffer:setData(data, 2, 5, 2)
  recorder.pass:send('Instances', buffer, 16, 32)
  local sent = recorder.calls[1][3] :: { { number } }
  expect.equal(#sent, 1, 'the uniform block contains one flat array')
  expectValues(sent[1], { 5, 6, 7, 8, 9, 10, 11, 12 })
  expect.equal(recorder.calls[1][4], 16, 'the byte offset remains recorded')
  expect.equal(recorder.calls[1][5], 32, 'the byte extent remains recorded')
  data[5] = 99
  buffer:setData({ 20, 21, 22, 23 }, 2, 1, 1)
  recorder.pass:send('Instances', buffer, 16, 16)
  buffer:release()
  expectValues(sent[1], { 5, 6, 7, 8, 9, 10, 11, 12 })
  expectValues(recorder.calls[2][3][1], { 20, 21, 22, 23 })
  expect.equal(recorder.bufferAcquisitions[1], buffer)
  expect.equal(recorder.bufferReleases[1], buffer)
  recorder:assertResourcesReleased()
end)

test('a shorter upload preserves its unwritten tail without reading the source tail', function()
  local recorder = render.new()
  local buffer = recorder:newBuffer('vec4', 3)
  buffer:setData({ 1, 2, 3, 4, 5, 6, 7, 8 }, 1, 1, 2)
  buffer:setData({ 11, 12, 13, 14, 0 / 0, math.huge }, 1, 1, 1)
  recorder.pass:send('Instances', buffer, 0, 48)
  local sent = recorder.calls[1][3] :: { { number } }
  expectValues(sent[1], { 11, 12, 13, 14, 5, 6, 7, 8, 0, 0, 0, 0 })
  buffer:release()
  recorder:assertResourcesReleased()
end)

test('buffer creation and writes reject unsupported formats and invalid ranges or values', function()
  local recorder = render.new()
  expect.raises(function()
    recorder:newBuffer('float', 1)
  end, 'buffer format')
  for _, capacity in { -1, 0, 1.5, math.huge, 0 / 0 } do
    expect.raises(function()
      recorder:newBuffer('vec4', capacity)
    end, 'buffer capacity')
  end
  local buffer = recorder:newBuffer('vec4', 2)
  local data = { 1, 2, 3, 4 }
  for _, range in
    { { 0, 1, 1 }, { 1.5, 1, 1 }, { 1, 0, 1 }, { 1, 1.5, 1 }, { 1, 1, -1 }, { 1, 1, 0.5 }, { 2, 1, 2 }, { 1, 2, 1 } }
  do
    expect.raises(function()
      buffer:setData(data, range[1], range[2], range[3])
    end, 'buffer')
  end
  for _, value in { math.huge, -math.huge, 0 / 0, 'invalid' } do
    expect.raises(function()
      buffer:setData({ 1, 2, 3, value }, 1, 1, 1)
    end, 'buffer value')
  end
  expect.equal(#recorder.bufferAcquisitions, 1, 'rejected acquisitions are not recorded')
  buffer:release()
  recorder:assertResourcesReleased()
end)

test('buffer sends reject unaligned and out-of-bounds ranges before recording', function()
  local recorder = render.new()
  local buffer = recorder:newBuffer('vec4', 2)
  for _, range in { { -16, 16 }, { 1, 16 }, { 0, 15 }, { 0, 0 }, { 16, 32 }, { math.huge, 16 }, { 0, 0 / 0 } } do
    expect.raises(function()
      recorder.pass:send('Instances', buffer, range[1], range[2])
    end, 'buffer range')
  end
  expect.equal(#recorder.calls, 0, 'invalid sends do not leave recorded calls')
  buffer:release()
  recorder:assertResourcesReleased()
end)

test('buffers participate in leak checks and cannot be used or released after release', function()
  local recorder = render.new()
  local buffer = recorder:newBuffer('vec4', 1)
  expect.raises(function()
    recorder:assertResourcesReleased()
  end, 'leaked buffer')
  buffer:release()
  expect.raises(function()
    buffer:setData({ 1, 2, 3, 4 }, 1, 1, 1)
  end, 'released buffer')
  expect.raises(function()
    recorder.pass:send('Instances', buffer, 0, 16)
  end, 'released buffer')
  expect.raises(function()
    buffer:release()
  end, 'buffer released twice')
  expect.equal(#recorder.bufferReleases, 1)
  recorder:assertResourcesReleased()
end)

test('table uniforms remain independent nested snapshots', function()
  local recorder = render.new()
  local values = { { 1, 2, 3, 4 } }
  recorder.pass:send('Instances', values)
  values[1][1] = 9
  expectValues(recorder.calls[1][3][1], { 1, 2, 3, 4 })
end)

test('compute shaders and graphics overloads retain their arguments and release once', function()
  local fake = native.new()
  local recorder = fake.events.render
  local graphics = lovr.graphics
  local options = { label = 'storage texture' }
  local compute = graphics.newShader('compute source', options)
  local raster = graphics.newShader('vertex source', 'fragment source', { label = 'raster' })
  local allocated = graphics.newTexture(64, 32, {
    format = 'rgba8',
    usage = { 'storage', 'sample' },
    storage = true,
    samples = 4,
  })
  local image = { pixels = true }
  local uploaded = graphics.newTexture(image, { mipmaps = true })
  local samplerOptions = { filter = 'nearest', wrap = 'clamp' }
  local sampler = graphics.newSampler(samplerOptions)

  expect.equal(compute.compute, 'compute source')
  expect.equal(compute.vertex, nil)
  expect.equal(compute.fragment, nil)
  expect.equal(compute.options, options)
  expect.equal(raster.vertex, 'vertex source')
  expect.equal(raster.fragment, 'fragment source')
  expect.equal(raster.compute, nil)
  expect.equal(allocated.width, 64)
  expect.equal(allocated.height, 32)
  expect.equal(allocated.options.format, 'rgba8')
  expect.equal(allocated.options.usage[1], 'storage')
  expect.equal(allocated.options.storage, true)
  expect.equal(allocated.options.samples, 4)
  expect.equal(allocated.uploads, 0)
  expect.equal(uploaded.uploads, 1)
  expect.equal(uploaded.options.mipmaps, true)
  expect.equal(sampler.options, samplerOptions)
  expect.equal(recorder.shaderAcquisitions[1], compute)
  expect.equal(recorder.shaderAcquisitions[2], raster)
  expect.equal(recorder.textureAcquisitions[1], allocated)
  expect.equal(recorder.textureAcquisitions[2], uploaded)
  expect.equal(recorder.samplerAcquisitions[1], sampler)

  expect.raises(function()
    recorder:assertResourcesReleased()
  end, 'leaked shader')
  compute:release()
  raster:release()
  allocated:release()
  uploaded:release()
  expect.equal(#recorder.shaderReleases, 2)
  expect.equal(#recorder.textureReleases, 2)
  expect.raises(function()
    recorder:assertResourcesReleased()
  end, 'leaked sampler')
  sampler:release()
  expect.equal(#recorder.samplerReleases, 1)
  expect.raises(function()
    sampler:release()
  end, 'sampler released twice')
  expect.raises(function()
    allocated:release()
  end, 'texture released twice')
  recorder:assertResourcesReleased()
  fake.assertResourcesReleased()
end)

test('compute pass calls snapshot shader state without becoming draws', function()
  local recorder = render.new()
  local shader = recorder:newShader 'compute source'
  recorder.pass:setShader(shader)
  recorder.pass:send('Scale', { 2, 3, 4 })
  recorder.pass:compute(4, 2, 1)
  local call = recorder.calls[3]
  expect.equal(call[1], 'compute')
  expect.equal(call[2], 4)
  expect.equal(call[3], 2)
  expect.equal(call[4], 1)
  expect.equal(call.draw, nil)
  expect.equal(call.state.setShader[1], shader)
  expectValues(recorder.calls[2][3], { 2, 3, 4 })
  recorder.pass:setShader 'next shader'
  expect.equal(call.state.setShader[1], shader, 'the compute command keeps its shader-state snapshot')
  shader:release()
  recorder:assertResourcesReleased()
end)

test('texture and sampler failures are consumed once before acquisition is recorded', function()
  local recorder = render.new()
  recorder.shaderFailure = 'injected shader failure'
  expect.raises(function()
    recorder:newShader 'compute source'
  end, 'injected shader failure')
  local shader = recorder:newShader 'compute source'
  expect.equal(#recorder.shaderAcquisitions, 1)

  recorder.textureFailure = 'injected texture failure'
  expect.raises(function()
    recorder:newTexture(8, 4, { format = 'rgba8' })
  end, 'injected texture failure')
  local texture = recorder:newTexture(8, 4, { format = 'rgba8' })
  expect.equal(#recorder.textureAcquisitions, 1)

  recorder.samplerFailure = 'injected sampler failure'
  expect.raises(function()
    recorder:newSampler { filter = 'nearest' }
  end, 'injected sampler failure')
  local sampler = recorder:newSampler { filter = 'nearest' }
  expect.equal(#recorder.samplerAcquisitions, 1)
  texture:release()
  sampler:release()
  expect.equal(#recorder.textureReleases, 1)
  expect.equal(#recorder.samplerReleases, 1)
  shader:release()
  expect.equal(#recorder.shaderReleases, 1)
  recorder:assertResourcesReleased()
end)

return test
