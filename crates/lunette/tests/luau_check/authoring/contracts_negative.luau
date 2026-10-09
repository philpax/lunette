local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local drops = require '@lunette-contracts/drops'
local vocabulary = require '@lunette-contracts/vocabulary'
local native = require '@lunette'
type Config = { read title: string, read height: number }
local definition = adapter.define {
  name = 'definition',
  requires = {
    panels.capability,
    interaction.capability,
    keyboard.capability,
    drops.capability,
  },
  provides = { panels.capability, keyboard.capability },
  init = function(ctx, config: Config, provide)
    local panelRegistry = ctx:require(panels.capability)
    local input, dropService = ctx:require(interaction.capability), ctx:require(drops.capability)
    local keys = ctx:require(keyboard.capability)
    provide:provide(panels.capability, 42) -- reject: number.
    provide:provide(keyboard.capability, { -- reject: missing field.
      all = function(_self: keyboard.Service): { keyboard.Keyboard }
        return {}
      end,
    })
    provide:provide(keyboard.capability, panelRegistry) -- reject: Service.
    local _wrongResult: number = panelRegistry:all() -- reject: number.
    panelRegistry:fromWindow(ctx, 'not a window') -- reject: Window.
    input:newPointer(ctx, { seat = 'not a seat' }) -- reject: Seat.
    local board = keys:new(ctx)
    board:setSize('wide', nil) -- reject: number.
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

local widened: plugin.Capability<unknown> = panels.capability -- reject: unknown.
local confused: plugin.Capability<keyboard.Service> = panels.capability -- reject: Service.
local runtime = adapter.runtime()
runtime:use(definition, { title = 42, height = 1 }) -- reject: string.
local instance = runtime:use(definition, { title = 'fixture', height = 1 })
instance:requestReload { title = 'fixture', height = 'tall' } -- reject: number.
local wrongName = adapter.define { name = 42, init = function(_ctx, _config: Config) end } -- reject: string.

-- A contract's data properties are read-only, so a substitute provider's record satisfies them covariantly.
local function mutate(surface: vocabulary.Surface, snapshot: native.PluginRuntimeSnapshot)
  surface.dead = true -- reject.
  snapshot.instances[1] = snapshot.instances[1] -- reject.
end

-- A receiver is a parameter, so an implementation narrowing it cannot answer the contract.
type NarrowKeyboards = keyboard.Service & { read privateState: number }
local function narrowNew(self: NarrowKeyboards, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
  return self:new(owner, options)
end
local wrongSelf: (keyboard.Service, keyboard.Owner, keyboard.Options?) -> keyboard.Keyboard = narrowNew -- reject.

return {
  widened = widened,
  confused = confused,
  definition = definition,
  wrongName = wrongName,
  mutate = mutate,
  wrongSelf = wrongSelf,
}
