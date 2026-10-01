local api = require './api'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local drops = require '@lunette-contracts/drops'
type Config = { read title: string, read height: number }
local definition = api.define {
  name = 'definition',
  requires = {
    panels = panels.capability,
    interaction = interaction.capability,
    keyboard = keyboard.capability,
    drops = drops.capability,
  },
  provides = { panels = panels.capability, keyboard = keyboard.capability },
  init = function(ctx, config: Config, provide)
    local panelRegistry = ctx:require(panels.capability)
    local input, dropService = ctx:require(interaction.capability), ctx:require(drops.capability)
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
    input:newPointer(ctx, { seat = 'not a seat' }) -- reject: Seat.
    local board = keys:new(ctx)
    board:typeText(42) -- reject: string.
    board:setVisible 'visible' -- reject: boolean.
    local _wrongBoard: panels.Panel = board -- reject: Panel.
    local _wrongConfig: number = config.title -- reject: number.
    dropService:onDropped(ctx, {
      run = function(drop)
        panelRegistry:all()[1]:setSize('wide', nil) -- reject: number.
        drop.pointer:withdraw(42) -- reject: Argument count.
      end,
    })
  end,
}

local widened: api.Capability<unknown> = panels.capability -- reject: unknown.
local confused: api.Capability<keyboard.Service> = panels.capability -- reject: Service.
local runtime = api.runtime()
runtime:use(definition, { title = 42, height = 1 }) -- reject: string.
local instance = runtime:use(definition, { title = 'fixture', height = 1 })
instance:reload { title = 'fixture', height = 'tall' } -- reject: number.
local wrongName = api.define { name = 42, init = function(_ctx, _config: Config) end } -- reject: string.

return { widened = widened, confused = confused, definition = definition, wrongName = wrongName }
