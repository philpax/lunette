-- Declaration correspondence is deliberately a runtime guarantee.

local api = require './api'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'

local function configWitness(value: {}): {}
  return value
end

local function definitions(service: keyboard.Service)
  local undeclared = api.define(configWitness, {}, {}, function(ctx)
    ctx:require(panels.capability):update()
    ctx:require(interaction.capability):newPointer(ctx):withdraw()
  end)
  local extra = api.define(configWitness, {}, {}, function(_ctx, _config, provide)
    provide:provide(keyboard.capability, service)
  end)
  local missing = api.define(configWitness, {}, { keyboard = keyboard.capability }, function() end)
  local duplicate = api.define(configWitness, {}, { keyboard = keyboard.capability }, function(_ctx, _config, provide)
    provide:provide(keyboard.capability, service)
    provide:provide(keyboard.capability, service)
  end)
  local escaped: api.Publisher? = nil
  local escapedDefinition = api.define(
    configWitness,
    {},
    { keyboard = keyboard.capability },
    function(_ctx, _config, provide)
      escaped = provide
      provide:provide(keyboard.capability, service)
    end
  )
  local function publishLater()
    local provide = escaped
    if provide then
      provide:provide(keyboard.capability, service)
    end
  end
  return { undeclared, extra, missing, duplicate, escapedDefinition }, publishLater
end

return definitions
