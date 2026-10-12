-- Coarse image metrics avoid exact shader goldens and exclude rasterization edges where appropriate.

local pixels = {}

export type Sample = { r: number, g: number, b: number, a: number }
export type ImageData = { width: number, height: number, values: { Sample } }
export type Summary = { low: number, high: number, nonblank: number, mean: number, alpha: number }
export type Difference = { alpha: number, color: number, shape: number, changed: number, x: number }

function pixels.read(image: Image): ImageData
  local width, height = image:getDimensions()
  local values = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r, g, b, a = image:getPixel(x, y)
      values[#values + 1] = { r = r, g = g, b = b, a = a }
    end
  end
  return { width = width, height = height, values = values }
end

function pixels.summary(image: ImageData): Summary
  local low, high, nonblank, alpha = math.huge, 0, 0, 0
  local sum = 0
  for _, p in image.values do
    local value = p.r + p.g + p.b
    low, high = math.min(low, value), math.max(high, value)
    nonblank += if value > 2 / 255 then 1 else 0
    sum += value
    alpha += p.a
  end
  return {
    low = low,
    high = high,
    nonblank = nonblank / #image.values,
    mean = sum / #image.values,
    alpha = alpha / #image.values,
  }
end

function pixels.difference(a: ImageData, b: ImageData): Difference
  local alpha, color, changed, weight, xMoment = 0, 0, 0, 0, 0
  local energyA, energyB = 0, 0
  for index, p in a.values do
    local q = b.values[index]
    energyA += p.r + p.g + p.b
    energyB += q.r + q.g + q.b
  end
  local scale = energyB / math.max(energyA, 1e-9)
  local shape = 0
  for index, p in a.values do
    local q = b.values[index]
    local delta = math.abs(p.a - q.a)
    alpha += delta
    color += math.abs(p.r - q.r) + math.abs(p.g - q.g) + math.abs(p.b - q.b)
    shape += math.abs(p.r * scale - q.r) + math.abs(p.g * scale - q.g) + math.abs(p.b * scale - q.b)
    if delta > 1 / 255 then
      changed += 1
    end
    weight += delta
    xMoment += delta * ((index - 1) % a.width) / a.width
  end
  return {
    alpha = alpha / #a.values,
    color = color / #a.values,
    shape = shape / #a.values,
    changed = changed / #a.values,
    x = xMoment / math.max(weight, 1e-9),
  }
end

function pixels.at(image: ImageData, x: number, y: number): Sample
  return image.values[y * image.width + x + 1]
end

return pixels
