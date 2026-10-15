-- A reusable, unnormalised forward complex FFT. The caller fills the real and imaginary arrays before each transform.

local fft = {}

export type Transform = {
  read size: number,
  read real: { number },
  read imag: { number },
  read transform: (Transform) -> (),
}

-- Sizes are positive powers of two. A size of one is an identity transform; zero has no transform.
function fft.new(size: number): Transform
  assert(size == size and size >= 1 and size <= 1048576 and size % 1 == 0, 'fft: invalid size')
  local stages = 0
  local remaining = size
  while remaining > 1 do
    assert(remaining % 2 == 0, 'fft: size must be a power of two')
    stages += 1
    remaining /= 2
  end

  local real: { number } = table.create(size, 0)
  local imag: { number } = table.create(size, 0)
  local reversed: { number } = table.create(size, 0)
  local cosine: { number } = table.create(math.floor(size / 2), 0)
  local sine: { number } = table.create(math.floor(size / 2), 0)
  for index = 0, size - 1 do
    local value = index
    local reverse = 0
    for _ = 1, stages do
      reverse = reverse * 2 + value % 2
      value = math.floor(value / 2)
    end
    reversed[index + 1] = reverse + 1
  end
  for index = 0, size / 2 - 1 do
    local angle = -2 * math.pi * index / size
    cosine[index + 1] = math.cos(angle)
    sine[index + 1] = math.sin(angle)
  end

  return table.freeze {
    size = size,
    real = real,
    imag = imag,
    transform = function(_self: Transform): ()
      for index = 1, size do
        local reverse = reversed[index]
        if reverse > index then
          real[index], real[reverse] = real[reverse], real[index]
          imag[index], imag[reverse] = imag[reverse], imag[index]
        end
      end
      local width = 2
      while width <= size do
        local half = width / 2
        local stride = size / width
        for first = 1, size, width do
          for offset = 0, half - 1 do
            local upper = first + offset
            local lower = upper + half
            local twiddle = offset * stride + 1
            local c = cosine[twiddle]
            local s = sine[twiddle]
            local r = c * real[lower] - s * imag[lower]
            local i = s * real[lower] + c * imag[lower]
            local upperReal = real[upper]
            local upperImag = imag[upper]
            real[upper] = upperReal + r
            imag[upper] = upperImag + i
            real[lower] = upperReal - r
            imag[lower] = upperImag - i
          end
        end
        width *= 2
      end
    end,
  }
end

return fft
