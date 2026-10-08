local testing = require '@testing'
local plugin = require '@lunette-plugin'
local boot = require './support/boot'
local expect = testing.expect
local test = testing.suite()

test('manager schema selects entries by default and retains explicit graph mode', function()
  local schema = require('@lunette-plugins/desktop/manager/config').schema
  expect.equal(schema.parse({}).view, 'entries')
  expect.equal(schema.parse({ view = 'graph' }).view, 'graph')
  expect.raises(function()
    schema.parse { view = 'unknown' }
  end)
end)

test('manager opens on an entry list with status and controller lifecycle actions', function()
  local running, _, _, _, _, public = boot({ visible = true, view = 'entries' }, {
    { id = 'fixture-entry', definition = plugin.define { name = 'fixture-entry', init = function() end } },
  })
  local ok, message = pcall(function()
    local listed = public:control 'entries'
    local item
    for _, row in listed.items do
      if row.id == 'entry/fixture-entry' then
        item = row
      end
    end
    expect.truthy(item, 'installed entries have stable visible ids')
    expect.truthy(item.label:find('active', 1, true), 'the list identifies actual state')
    local ids = {}
    for _, control in public:panel():describe().controls do
      ids[control.id] = true
    end
    expect.equal(ids['zoom-in'], nil, 'graph navigation does not crowd entry management')
    expect.equal(ids['remove-value'], nil, 'configuration editing appears only in its tab')
    expect.equal(public:control('close').label, 'X', 'the shared titlebar close is visible')
    local pointer = public:pointer()
    public:click(pointer, 'entries', 'entry/fixture-entry')
    public:click(pointer, 'disable')
    for _, entry in running.service:entries() do
      if entry.id == 'fixture-entry' then
        expect.equal(entry.enabled, false)
      end
    end
    public:click(pointer, 'enable')
    public:click(pointer, 'graph-view')
    expect.truthy(public:control 'graph', 'the diagnostic graph remains separately accessible')
    public:click(pointer, 'entries-view')
    expect.truthy(public:control 'entries')
    public:click(pointer, 'close')
    expect.equal(public:panel():describe().visible, false)
  end)
  running.runtime:close()
  if not ok then
    error(message, 0)
  end
end)

return test
