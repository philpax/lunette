local api = require './api'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'

type Config = { read title: string, read height: number }
local function configWitness(value: Config): Config
  return value
end

local definition = api.define(
  configWitness,
  { panels = panels.capability, interaction = interaction.capability, keyboard = keyboard.capability },
  { panels = panels.capability, keyboard = keyboard.capability },
  function(ctx, config: Config, provide)
    local panelRegistry = ctx:require(panels.capability)
    local input = ctx:require(interaction.capability)
    local keys = ctx:require(keyboard.capability)
    provide:provide(panels.capability, 42) -- reject: number.
    provide:provide(keyboard.capability, {
      all = function(_self: keyboard.Service): { keyboard.Keyboard }
        return {}
      end,
    }) -- reject: missing field.
    provide:provide(keyboard.capability, panelRegistry) -- reject: Service.
    local _wrongResult: number = panelRegistry:all() -- reject: number.
    panelRegistry:fromWindow(ctx, 'not a window') -- reject: Window.
    input:scrollDelta('not a delta', 1) -- reject: number.
    local board = keys:new(ctx)
    board:typeText(42) -- reject: string.
    board:setVisible 'visible' -- reject: boolean.
    local _wrongBoard: panels.Panel = board -- reject: Panel.
    local _wrongConfig: number = config.title -- reject: number.
    panelRegistry:onDropped(ctx, nil, function(panel, pointer)
      panel:setSize('wide', nil) -- reject: number.
      pointer:withdraw(42) -- reject: Argument count.
    end)
  end
)

local widened: api.Capability<unknown> = panels.capability -- reject: unknown.
local confused: api.Capability<keyboard.Service> = panels.capability -- reject: Service.
local runtime = api.runtime()
runtime:use(definition, { title = 42, height = 1 }) -- reject: string.
local instance = runtime:use(definition, { title = 'fixture', height = 1 })
instance:reload { title = 'fixture', height = 'tall' } -- reject: number.
local wrongInitializer = api.define(configWitness, {}, {}, function(_ctx, config: number) end) -- reject: number.

return { widened = widened, confused = confused, definition = definition, wrongInitializer = wrongInitializer }
