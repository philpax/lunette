local testing = require '@testing'
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local expect = testing.expect
local fixture = {}

function fixture.entry(service, id)
  for _, current in service:entries() do
    if current.id == id then
      return current
    end
  end
  return nil
end

function fixture.knownEntry(service, id)
  for _, current in service:catalog() do
    if current.id == id then
      return current
    end
  end
  return nil
end

function fixture.report(needle)
  local reports = testing.takeReports()
  expect.equal(#reports, 1, table.concat(reports, '\n'))
  expect.truthy(reports[1]:find(needle, 1, true), reports[1])
end

function fixture.configured(init)
  return plugin.consumer({
    name = 'managed-settings',
    schema = schema.object { value = schema.default(schema.number { integer = true, minimum = 0 })(1) },
    init = init,
  }).definition
end

return fixture
