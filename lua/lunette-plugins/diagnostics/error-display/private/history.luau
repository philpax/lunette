-- The overlay's record of reports: repeated reports collapse into one entry with a count, dismissal clears what is
-- new without forgetting it, and the oldest entries leave once the history is full. Every function returns a new
-- value, so the record can be published through a store.

local errors = require '@lunette-contracts/errors'

local history = {}

export type Entry = {
  -- A stable identity among the entries, usable as an element key.
  read id: string,
  read message: string,
  read traceback: string,
  -- Reports with this message and traceback, including those the stream suppressed.
  read count: number,
  -- Reports since the last dismissal.
  read unseen: number,
  -- The stream sequence of the latest report.
  read sequence: number,
}

export type History = {
  -- Newest report first.
  read entries: { read [number]: Entry },
  read limit: number,
  -- The number of entries recorded so far, which names the next entry.
  read created: number,
}

export type Page = {
  read entries: { read [number]: Entry },
  -- Positions from one of the first and last entry shown, and the total; first exceeds last when the list is empty.
  read first: number,
  read last: number,
  read total: number,
  -- The page actually shown, after clamping.
  read index: number,
  read pages: number,
}

function history.new(limit: number): History
  assert(limit >= 1, 'error display: the history keeps at least one entry')
  return table.freeze { entries = table.freeze({} :: { Entry }), limit = limit, created = 0 }
end

-- Records a report, moving its entry to the front. The stream identifies a repeat by its message and traceback, and
-- so does the history.
function history.record(state: History, report: errors.Report): History
  local occurrences = 1 + report.suppressed
  local entries: { Entry } = {}
  local previous: Entry? = nil
  for _, entry in state.entries do
    if previous == nil and entry.message == report.message and entry.traceback == report.traceback then
      previous = entry
    else
      table.insert(entries, entry)
    end
  end
  local created = state.created
  local id: string
  if previous then
    id = previous.id
  else
    created += 1
    id = `report-{created}`
  end
  table.insert(
    entries,
    1,
    table.freeze {
      id = id,
      message = report.message,
      traceback = report.traceback,
      count = (if previous then previous.count else 0) + occurrences,
      unseen = (if previous then previous.unseen else 0) + occurrences,
      sequence = report.sequence,
    }
  )
  while #entries > state.limit do
    table.remove(entries)
  end
  return table.freeze { entries = table.freeze(entries), limit = state.limit, created = created }
end

-- Clears what is new; the entries stay in the history.
function history.dismiss(state: History): History
  local entries: { Entry } = {}
  for index, entry in state.entries do
    entries[index] = if entry.unseen == 0
      then entry
      else table.freeze {
        id = entry.id,
        message = entry.message,
        traceback = entry.traceback,
        count = entry.count,
        unseen = 0,
        sequence = entry.sequence,
      }
  end
  return table.freeze { entries = table.freeze(entries), limit = state.limit, created = state.created }
end

-- The entries with reports since the last dismissal, newest first.
function history.unseen(state: History): { Entry }
  local list: { Entry } = {}
  for _, entry in state.entries do
    if entry.unseen > 0 then
      table.insert(list, entry)
    end
  end
  return list
end

-- One page of a list, clamping the page index into range.
function history.page(list: { read [number]: Entry }, index: number, size: number): Page
  local total = #list
  local pages = math.max(1, math.ceil(total / size))
  local clamped = math.clamp(index, 1, pages)
  local first = (clamped - 1) * size + 1
  local last = math.min(total, clamped * size)
  local shown: { Entry } = {}
  for position = first, last do
    table.insert(shown, list[position])
  end
  return table.freeze {
    entries = table.freeze(shown),
    first = first,
    last = last,
    total = total,
    index = clamped,
    pages = pages,
  }
end

return history
