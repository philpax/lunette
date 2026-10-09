local testing = require '@testing'
local expect = testing.expect
local editor = require '../../editor'

local fixture = {}

function fixture.row(model, path)
  for _, item in editor.rows(model) do
    local matches = #item.path == #path
    for index, key in path do
      matches = matches and item.path[index] == key
    end
    if matches then
      return item
    end
  end
  error('missing row ' .. table.concat(path, '.'))
end

function fixture.change(operation, ...)
  local model, problem = operation(...)
  assert(model, if problem then problem.message else 'missing draft')
  expect.equal(problem, nil)
  return model
end

function fixture.reject(model, operation, code, ...)
  local draft = editor.draft(model)
  local result, problem = operation(model, ...)
  expect.equal(result, nil)
  expect.equal(problem.code, code)
  expect.truthy(type(problem.message) == 'string' and #problem.message > 0)
  expect.truthy(table.isfrozen(problem) and table.isfrozen(problem.path))
  expect.equal(editor.draft(model), draft)
  return problem
end

return fixture
