-- A fixed-capacity ring of the most recent samples, for rolling statistics that never grow with the session's length.
local history = {}

export type History = {
  read capacity: number,
  samples: { number },
  -- Where the next sample goes, which is the oldest sample once the ring is full.
  next: number,
}

function history.new(capacity: number): History
  assert(capacity >= 1 and capacity % 1 == 0, 'history: the capacity is a positive integer')
  local samples: { number } = {}
  return { capacity = capacity, samples = samples, next = 1 }
end

function history.push(ring: History, value: number): ()
  ring.samples[ring.next] = value
  ring.next = ring.next % ring.capacity + 1
end

function history.count(ring: History): number
  return #ring.samples
end

function history.latest(ring: History): number?
  if #ring.samples == 0 then
    return nil
  end
  return ring.samples[(ring.next - 2) % ring.capacity + 1]
end

function history.sum(ring: History): number
  local total = 0
  for _, value in ring.samples do
    total += value
  end
  return total
end

function history.mean(ring: History): number?
  local count = #ring.samples
  return if count == 0 then nil else history.sum(ring) / count
end

function history.maximum(ring: History): number?
  local largest: number? = nil
  for _, value in ring.samples do
    if largest == nil or value > largest then
      largest = value
    end
  end
  return largest
end

-- The samples from oldest to newest.
function history.values(ring: History): { number }
  local count = #ring.samples
  if count < ring.capacity then
    return table.clone(ring.samples)
  end
  local ordered: { number } = {}
  for offset = 0, count - 1 do
    ordered[offset + 1] = ring.samples[(ring.next - 1 + offset) % count + 1]
  end
  return ordered
end

return history
