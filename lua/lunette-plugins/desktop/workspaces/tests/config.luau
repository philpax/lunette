local testing = require '@testing'
local expect = testing.expect
local config = require '../config'
local editor = require '@lunette-plugins/desktop/manager/editor'
local test = testing.suite()

local function row(model, path)
  for _, item in editor.rows(model) do
    if #item.path ~= #path then
      continue
    end
    local matches = true
    for index, key in path do
      if item.path[index] ~= key then
        matches = false
      end
    end
    if matches then
      return item
    end
  end
  error('missing row ' .. table.concat(path, '.'))
end

local function change(operation, ...)
  local model, problem = operation(...)
  assert(model, if problem then problem.message else 'missing draft')
  expect.equal(problem, nil)
  return model
end

test('workspace metadata omits removed physical settings', function()
  local metadata = config.schema.inspect()
  expect.equal(metadata.fields.modifiers, nil)
  local workspace = metadata.fields.workspaces.child.child.child
  expect.equal(workspace.fields.key, nil)
  expect.equal(workspace.fields.name.kind, 'string')
end)

test('names-only workspace configuration retains add, remove, and reset editing', function()
  local initial = { workspaces = { { name = 'main' }, { name = 'web' } }, follow = false }
  local model = editor.new(config.schema.inspect(), initial)
  expect.truthy(row(model, { 'workspaces' }).canAdd, 'the array remains editable')
  expect.truthy(row(model, { 'workspaces', 2 }).canRemove, 'the entry remains removable')
  local added = change(editor.add, model, { 'workspaces' })
  expect.equal(#editor.draft(added).workspaces, 3)
  local named = change(editor.set, added, { 'workspaces', 3, 'name' }, 'chat')
  expect.equal(config.schema.parse(editor.draft(named)).workspaces[3].name, 'chat')
  local removed = change(editor.remove, named, { 'workspaces', 2 })
  expect.equal(#editor.draft(removed).workspaces, 2)
  expect.equal(editor.draft(removed).workspaces[1].name, 'main')
  expect.equal(editor.draft(removed).workspaces[2].name, 'chat')
  local reset = change(editor.reset, removed, { 'workspaces' })
  local defaults = config.schema.parse {}
  expect.equal(#editor.draft(reset).workspaces, #defaults.workspaces)
  for index, workspace in defaults.workspaces do
    expect.equal(editor.draft(reset).workspaces[index].name, workspace.name)
  end
  local whole = change(editor.reset, reset, {})
  expect.equal(editor.draft(whole).follow, defaults.follow)
  expect.equal(#editor.draft(whole).workspaces, #defaults.workspaces)
end)

test('workspace migration rejects removed fields in parse, patches, and resolved bases', function()
  local defaults = config.schema.parse {}
  for _, case in
    {
      { value = { modifiers = { 'alt' } }, message = 'workspaces modifiers are removed' },
      { value = { workspaces = { { name = 'main', key = '1' } } }, message = 'workspaces key is removed' },
    }
  do
    expect.raises(function()
      config.schema.parse(case.value, 'desktop/workspaces')
    end, case.message)
    expect.raises(function()
      config.schema.resolve(case.value, defaults, 'desktop/workspaces')
    end, case.message)
    expect.raises(function()
      config.schema.resolve({}, case.value, 'desktop/workspaces')
    end, case.message)
  end
end)

return test
