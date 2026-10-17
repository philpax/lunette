local testing = require '@testing'
local rows = require '../private/rows'
local expect = testing.expect
local test = testing.suite()

local function descriptor(id: string, label: string, group: string): any
  return { id = id, label = label, group = group, enabled = true, selected = false, token = {} }
end

local function titles(list: { rows.Row }): string
  local parts: { string } = {}
  for _, row in list do
    table.insert(parts, if row.kind == 'group' then `[{row.title}]` else row.title)
  end
  return table.concat(parts, ' ')
end

test('actions sit under a heading per group, groups and actions in alphabetical order, ungrouped last', function()
  local list = rows.rows {
    descriptor('a', 'Plugins', 'Session'),
    descriptor('b', 'monitor-b', 'Monitors'),
    descriptor('c', 'Accessibility', 'Session'),
    descriptor('d', 'Loose', ''),
    descriptor('e', 'Backdrop', 'Appearance'),
    descriptor('f', 'Monitor-a', 'Monitors'),
  }
  expect.equal(
    titles(list),
    '[Appearance] Backdrop [Monitors] Monitor-a monitor-b [Session] Accessibility Plugins [Other] Loose',
    'the order ignores case'
  )
end)

test('numbers in labels sort by value', function()
  local list = rows.rows {
    descriptor('a', 'Workspace 10', 'Workspaces'),
    descriptor('b', 'Workspace 2', 'Workspaces'),
    descriptor('c', 'Workspace 1', 'Workspaces'),
    descriptor('d', 'Workspace', 'Workspaces'),
  }
  expect.equal(titles(list), '[Workspaces] Workspace Workspace 1 Workspace 2 Workspace 10')
end)

test('headings never share a key with an action, whatever the action id', function()
  local list = rows.rows { descriptor('%00Session', 'Odd', 'Session'), descriptor('x', 'Plain', 'Session') }
  local keys: { [string]: boolean } = {}
  for _, row in list do
    expect.equal(keys[row.key], nil, `the key {row.key} is unique`)
    keys[row.key] = true
  end
end)

return test
