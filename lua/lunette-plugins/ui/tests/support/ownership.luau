local plugin = require '@lunette-plugin'
local theme = require '@lunette-plugins/ui/theme'
local themes = require '@lunette-contracts/theme'
local fixture = {}
local sequence = 0

function fixture.panel(running, _owner, focusService, registry)
  sequence += 1
  local name = 'testing/ui-control-provider-' .. sequence
  local capability = plugin.capability { name = name, schema = 1 }
  local state
  local providerContext
  local provider = running.session:use(plugin.define {
    name = name,
    provides = { controls = capability },
    requires = { theme = themes.capability },
    init = function(context, _config, publish)
      providerContext = context
      publish:provide(capability, {})
    end,
  })
  local consumer = running.session:use(plugin.define {
    name = 'testing/ui-control-consumer-' .. sequence,
    requires = { controls = capability },
    init = function(context)
      state = {
        dead = false,
        visible = true,
        cancelling = false,
        revision = 1,
        owner = context,
        context = providerContext,
        focus = focusService,
        logicalWidth = 200,
        logicalHeight = 100,
        theme = theme.materialize(theme.DEFAULT, providerContext:require(themes.capability):getFont()),
        spec = theme.DEFAULT,
        themes = providerContext:require(themes.capability),
        refresh = function() end,
        controls = {},
        owners = registry or {},
        nextOrder = 0,
        captures = {},
        hovered = {},
        pointerHover = {},
        pendingInput = {},
      }
    end,
  })
  return state, consumer, provider
end

function fixture.options(id)
  return { id = id, bounds = { x = 10, y = 10, width = 30, height = 30 } }
end

function fixture.widget(_host, receiver)
  return {
    kind = 'region',
    methods = {},
    receiver = receiver,
    wantsKeyboard = false,
    pointer = function() end,
    items = function()
      return {}
    end,
    visual = function(value)
      return value
    end,
  }
end

return fixture
