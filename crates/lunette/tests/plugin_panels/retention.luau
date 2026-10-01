local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local definition = require('@lunette-plugins/panels').definition

local runtime = plugin.runtime()
local provider = runtime:use(definition, {})
provider:enable()
local service
local owner
local consumer = runtime:use(
  plugin.define {
    name = 'retention-1',
    requires = { panels = contracts.capability },
    init = function(context)
      service = context:require(contracts.capability)
      owner = context
    end,
  },
  {}
)
consumer:enable()

return {
  cycle = function(payload, sourceDies)
    local source = { id = 99, dead = false, width = 800, height = 600, payload = payload }
    function source:getTexture()
      return nil
    end
    local panel = service:fromWindow(owner, source, { chrome = false })
    assert(#service:all() == 1)
    if sourceDies then
      source.dead = true
      panel:update()
      assert(panel.dead)
    else
      assert(panel:destroy(owner))
    end
    assert(not panel:destroy())
    assert(#service:all() == 0)
    assert(service:forSource(source) == nil)
  end,
  close = function()
    local source = { id = 100, dead = false, width = 800, height = 600 }
    function source:getTexture()
      return nil
    end
    local panel = service:fromWindow(owner, source, { chrome = false })
    consumer:disable()
    assert(panel.dead)
    assert(not panel:destroy())
    provider:disable()
    assert(not panel:destroy())
    runtime:close()
  end,
}
