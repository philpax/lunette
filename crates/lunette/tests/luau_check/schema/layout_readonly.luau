local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'

local function apply(panels: { read [number]: layouts.Panel }, _options: unknown?): ()
  for _, panel in panels do
    panel:setPose(lovr.math.newMat4())
  end
end

local function register(service: layouts.Service, owner: plugin.Context): ()
  service:register(owner, { name = 'readonly-layout', apply = apply })
end

return register
