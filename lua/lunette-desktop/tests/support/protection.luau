local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local desktop = require '@lunette-desktop'
local composition = require '@lunette-contracts/composition'

local fixture = {}

function fixture.boot(patches)
  local native = testing.native()
  local service
  local observer = plugin.define {
    name = 'desktop-protection-observer',
    requires = { composition = composition.capability },
    init = function(context)
      service = context:require(composition.capability)
    end,
  }
  local changes = table.clone(patches or {})
  changes[#changes + 1] = { insert = { id = 'desktop-protection-observer', definition = observer } }
  desktop.run { patches = changes }
  lovr.load()
  return assert(service), native
end

function fixture.entries(service)
  local result = {}
  for _, entry in service:entries() do
    result[entry.id] = entry
  end
  return result
end

function fixture.finish(native)
  expect.equal(#testing.host.shutdown(), 0, 'the desktop shuts down without failures')
  native.assertResourcesReleased()
end

local MANDATORY = {
  'composition',
  'frame',
  'surfaces',
  'focus',
  'interaction',
  'laser',
  'keyboard',
  'ui',
  'menu',
  'desktop/pointing',
  'desktop/keyboard',
  'desktop/menu',
  'desktop/actions',
  'desktop/manager',
}

function fixture.assertProtected(service)
  local current = fixture.entries(service)
  for _, id in MANDATORY do
    expect.truthy(current[id].protected, id .. ' protects the VR recovery path')
    for _, operation in { 'disable', 'reload', 'remove', 'recover' } do
      expect.raises(function()
        service[operation](service, id)
      end, 'required for management or recovery', id .. ' rejects ' .. operation)
    end
  end
end

return fixture
