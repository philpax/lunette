-- Runtime checks enforce declaration correspondence.

local api = require './api'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'

local function definitions(service: keyboard.Service)
  local undeclared = api.define {
    name = 'undeclared',
    init = function(ctx)
      ctx:require(panels.capability):update()
      ctx:require(interaction.capability):newPointer(ctx):withdraw()
    end,
  }
  local extra = api.define {
    name = 'extra',
    init = function(_ctx, _config: {}, provide)
      provide:provide(keyboard.capability, service)
    end,
  }
  local missing = api.define {
    name = 'missing',
    provides = { keyboard = keyboard.capability },
    init = function() end,
  }
  local duplicate = api.define {
    name = 'duplicate',
    provides = { keyboard = keyboard.capability },
    init = function(_ctx, _config: {}, provide)
      provide:provide(keyboard.capability, service)
      provide:provide(keyboard.capability, service)
    end,
  }
  local escaped: api.Publisher? = nil
  local escapedDefinition = api.define {
    name = 'escapedDefinition',
    provides = { keyboard = keyboard.capability },
    init = function(_ctx, _config: {}, provide)
      escaped = provide
      provide:provide(keyboard.capability, service)
    end,
  }
  local function publishLater()
    local provide = escaped
    if provide then
      provide:provide(keyboard.capability, service)
    end
  end
  return { undeclared, extra, missing, duplicate, escapedDefinition }, publishLater
end

return definitions
