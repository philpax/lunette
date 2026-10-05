local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local frame = require '@lunette-plugins/frame'
local surfaces = require '@lunette-plugins/surfaces'
local surfaceContract = require '@lunette-contracts/surfaces'
local manager = require '@lunette-plugins/desktop/manager'
local controller = require '@lunette-plugins/desktop/manager/controller'

return function(config, additions, protected)
  local fake = testing.native()
  local font = {
    getHeight = function()
      return 1
    end,
    getLineSpacing = function()
      return 1
    end,
    getWidth = function(_, text)
      return #text * 0.5
    end,
    getLines = function(_, text)
      local result = {}
      for line in (text .. '\n'):gmatch '(.-)\n' do
        result[#result + 1] = line
      end
      return result
    end,
  }
  lovr.graphics.getDefaultFont = function()
    return font
  end
  for _, name in
    {
      'push',
      'pop',
      'transform',
      'translate',
      'scale',
      'setShader',
      'setMaterial',
      'setFont',
      'setCullMode',
      'setDepthTest',
      'setDepthWrite',
    }
  do
    fake.events.pass[name] = function(_, ...)
      fake.events.draw[#fake.events.draw + 1] = { name, ... }
    end
  end
  local surfaceService
  local observed = plugin.define {
    name = 'surface-observer',
    requires = { surfaces = surfaceContract.capability },
    init = function(context)
      surfaceService = context:require(surfaceContract.capability)
    end,
  }
  frame.install { start = function() end, stop = function() end }
  local entries = {
    { id = 'frame', definition = frame.definition },
    { id = 'surfaces', definition = surfaces.definition },
    { id = 'desktop/manager', definition = manager, config = config or {} },
    { id = 'observer', definition = observed },
  }
  for _, entry in additions or {} do
    entries[#entries + 1] = entry
  end
  local state
  local new = controller.new
  controller.new = function(...)
    state = new(...)
    return state
  end
  local ok, running = pcall(management.start, entries, { protected = protected or { 'desktop/manager' } })
  controller.new = new
  if not ok then
    error(running, 0)
  end
  return running, fake, function()
    return surfaceService:all()
  end, state
end
