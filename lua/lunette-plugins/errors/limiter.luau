-- The error stream's bounded, time-window limiter.
--
-- The limiter owns no clock. Each activation gets a fresh instance, and callers
-- supply the time for each occurrence so headless tests can drive it directly.

local limiter = {}

export type Limiter = {
  read window: number,
  read maxKeys: number,
  read record: (Limiter, string, number) -> (boolean, number),
  read suppressedCount: (Limiter, string) -> number,
}

type Entry = { suppressed: number, reportedAt: number }

local function touch(order: { string }, key: string)
  for index = 1, #order do
    if order[index] == key then
      table.remove(order, index)
      break
    end
  end
  order[#order + 1] = key
end

local function evict(entries: { [string]: Entry }, order: { string }, maxKeys: number)
  while #order > maxKeys do
    local oldest = table.remove(order, 1)
    if oldest then
      entries[oldest] = nil
    end
  end
end

function limiter.new(window: number, maxKeys: number): Limiter
  local entries: { [string]: Entry } = {}
  local order: { string } = {}

  local created: Limiter = {
    window = window,
    maxKeys = maxKeys,
    record = function(_self: Limiter, key: string, now: number): (boolean, number)
      if type(key) ~= 'string' then
        error('errors: a rate-limit key is a string, not a ' .. type(key), 2)
      end
      if type(now) ~= 'number' then
        error('errors: a rate limiter is told the time, and ' .. type(now) .. ' is not one', 2)
      end

      local entry = entries[key]
      if not entry then
        entries[key] = { suppressed = 0, reportedAt = now }
        order[#order + 1] = key
        evict(entries, order, maxKeys)
        return true, 0
      end

      touch(order, key)
      if now - entry.reportedAt < window then
        entry.suppressed += 1
        return false, 0
      end

      local suppressed = entry.suppressed
      entry.suppressed = 0
      entry.reportedAt = now
      return true, suppressed
    end,
    suppressedCount = function(_self: Limiter, key: string): number
      local entry = entries[key]
      return entry and entry.suppressed or 0
    end,
  }
  return created
end

return limiter
