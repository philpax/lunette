-- Limits repeated error reports by caller-supplied timestamps and a bounded key set.
local limiter = {}

export type Limiter = {
  read record: (Limiter, string, number) -> (boolean, number),
}

type Entry = { suppressed: number, reportedAt: number }

function limiter.new(window: number, maxKeys: number): Limiter
  local entries: { [string]: Entry } = {}
  -- Keys from least to most recently recorded; the least recent is forgotten first.
  local order: { string } = {}

  return {
    record = function(_self: Limiter, key: string, now: number): (boolean, number)
      local entry = entries[key]
      if not entry then
        entries[key] = { suppressed = 0, reportedAt = now }
        order[#order + 1] = key
        while #order > maxKeys do
          entries[table.remove(order, 1) :: string] = nil
        end
        return true, 0
      end

      table.remove(order, table.find(order, key) :: number)
      order[#order + 1] = key
      if now - entry.reportedAt < window then
        entry.suppressed += 1
        return false, 0
      end

      local suppressed = entry.suppressed
      entry.suppressed = 0
      entry.reportedAt = now
      return true, suppressed
    end,
  }
end

return limiter
