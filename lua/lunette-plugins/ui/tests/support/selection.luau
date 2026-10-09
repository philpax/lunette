local selection = {}

function selection.state(bounds)
  return {
    live = true,
    revision = 0,
    cancels = {},
    reports = {},
    focuses = 0,
    bounds = bounds,
    theme = { rowHeight = 20, padding = 2, spacing = 3 },
    pointer = {},
  }
end

function selection.host(state)
  return {
    live = function()
      return state.live
    end,
    changed = function()
      state.revision += 1
    end,
    cancel = function(reason)
      table.insert(state.cancels, reason)
      if state.onCancel then
        state.onCancel()
      end
    end,
    focus = function()
      state.focuses += 1
      return true
    end,
    blur = function()
      state.focuses += 1
      return true
    end,
    bounds = function()
      return state.bounds
    end,
    theme = function()
      return state.theme
    end,
    callback = function(label, run)
      local ok, message = pcall(run)
      if not ok then
        table.insert(state.reports, { label = label, message = tostring(message) })
      end
      return ok
    end,
  }
end

function selection.event(state, kind, x, y, extra, pointer, item)
  local event = { kind = kind, x = x, y = y, pointer = pointer or state.pointer, inside = true, captured = true }
  if kind == 'press' or kind == 'release' or kind == 'cancel' then
    event.button = 'left'
  end
  if kind == 'cancel' then
    event.reason = 'disabled'
  end
  if extra then
    for key, value in extra do
      event[key] = value
    end
  end
  if item == nil and x and y then
    for _, row in state:items() do
      local bounds = row.bounds
      if x >= bounds.x and x < bounds.x + bounds.width and y >= bounds.y and y < bounds.y + bounds.height then
        item = row.id
        break
      end
    end
  end
  state.widget.pointer(event, item)
end

function selection.rows(count, label)
  local items = {}
  for index = 1, count do
    items[index] = { id = tostring(index), label = label .. index }
  end
  return items
end

return selection
