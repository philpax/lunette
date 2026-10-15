local testing = require '@testing'
local expect = testing.expect
local fft = require '../private/fft'
local test = testing.suite()

local function dft(real: { number }, imag: { number }): ({ number }, { number })
  local size = #real
  local resultReal, resultImag = {}, {}
  for bin = 0, size - 1 do
    local r, i = 0, 0
    for sample = 0, size - 1 do
      local angle = -2 * math.pi * bin * sample / size
      r += real[sample + 1] * math.cos(angle) - imag[sample + 1] * math.sin(angle)
      i += real[sample + 1] * math.sin(angle) + imag[sample + 1] * math.cos(angle)
    end
    resultReal[bin + 1], resultImag[bin + 1] = r, i
  end
  return resultReal, resultImag
end

test('fft_matches_dft_oracle', function()
  local seed = 1729
  local function random(): number
    seed = seed * 48271 % 2147483647
    return seed / 2147483647 * 2 - 1
  end
  for _, size in { 1, 2, 4, 8, 16, 32, 64 } do
    local transform = fft.new(size)
    local reusableReal, reusableImag = transform.real, transform.imag
    for kind = 1, 7 do
      local real, imag = {}, {}
      for index = 1, size do
        if kind == 1 then
          real[index] = 0
        elseif kind == 2 then
          real[index] = if index == 1 then 1 else 0
        elseif kind == 3 then
          real[index] = 0.75
        elseif kind == 4 then
          real[index] = math.sin(2 * math.pi * (index - 1) / size)
        elseif kind == 5 then
          real[index] = math.cos(2 * math.pi * math.floor(size / 2) * (index - 1) / size)
        else
          real[index] = random()
        end
        imag[index] = if kind == 7 then random() else 0
        transform.real[index], transform.imag[index] = real[index], imag[index]
      end
      local wantedReal, wantedImag = dft(real, imag)
      transform:transform()
      expect.equal(transform.real, reusableReal, 'the real array is reused')
      expect.equal(transform.imag, reusableImag, 'the imaginary array is reused')
      for bin = 1, size do
        expect.near(transform.real[bin], wantedReal[bin], 1e-10 * size, 'the DFT real component')
        expect.near(transform.imag[bin], wantedImag[bin], 1e-10 * size, 'the DFT imaginary component')
      end
    end
  end
end)

test('zero and non-power-of-two transform sizes are rejected', function()
  for _, size in { 0, -1, 3, 6, 1.5, math.huge, 0 / 0, 2097152 } do
    expect.raises(function()
      fft.new(size)
    end, 'fft:')
  end
  local transform = fft.new(1)
  transform.real[1], transform.imag[1] = 4, -3
  transform:transform()
  expect.equal(transform.real[1], 4, 'the size-one real identity')
  expect.equal(transform.imag[1], -3, 'the size-one imaginary identity')
end)

test('impulses DC and bin-centred tones have the expected large transforms', function()
  for _, size in { 512, 1024, 2048 } do
    local transform = fft.new(size)
    for index = 1, size do
      transform.real[index], transform.imag[index] = if index == 1 then 1 else 0, 0
    end
    transform:transform()
    for bin = 1, size do
      expect.near(transform.real[bin], 1, 1e-12, 'the impulse spectrum')
      expect.near(transform.imag[bin], 0, 1e-12, 'the impulse phase')
    end
    for index = 1, size do
      transform.real[index], transform.imag[index] = 0.25, 0
    end
    transform:transform()
    expect.near(transform.real[1], size / 4, 1e-10, 'the DC bin')
    for bin = 2, size do
      expect.near(transform.real[bin], 0, 1e-10, 'the other DC bins')
    end
    for index = 1, size do
      transform.real[index], transform.imag[index] = math.sin(2 * math.pi * 7 * (index - 1) / size), 0
    end
    transform:transform()
    expect.near(transform.imag[8], -size / 2, 1e-9, 'the positive-frequency tone')
    expect.near(transform.imag[size - 6], size / 2, 1e-9, 'the negative-frequency tone')
  end
end)

return test
