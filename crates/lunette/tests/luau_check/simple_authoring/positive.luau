local api = require './api'
local panels = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local focus = require '@lunette-contracts/focus'
local drops = require '@lunette-contracts/drops'

type Config = { read title: string, read height: number }
local function build(
  panelService: panels.Service,
  interactionService: interaction.Service,
  keyboardService: keyboard.Service
)
  local implementation: keyboard.Service = {
    new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
      return keyboardService:new(owner, options)
    end,
  }
  local provider = api.define {
    name = 'provider',
    provides = { panels = panels.capability, interaction = interaction.capability, keyboard = keyboard.capability },
    init = function(_ctx, config: Config, provide)
      local height: number = config.height
      local title: string = config.title
      assert(height > 0 and #title > 0)
      provide:provide(panels.capability, panelService)
      provide:provide(interaction.capability, interactionService)
      provide:provide(keyboard.capability, implementation)
    end,
  }
  local consumer = api.define {
    name = 'consumer',
    requires = {
      panels = panels.capability,
      interaction = interaction.capability,
      keyboard = keyboard.capability,
      focus = focus.capability,
      drops = drops.capability,
    },
    init = function(ctx, config, _provide)
      local panelRegistry: panels.Service = ctx:require(panels.capability)
      local input: interaction.Service = ctx:require(interaction.capability)
      local keys: keyboard.Service = ctx:require(keyboard.capability)
      local focused: focus.Service = ctx:require(focus.capability)
      local dropped: drops.Service = ctx:require(drops.capability)
      panelRegistry:update()
      local pointer: interaction.Pointer = input:newPointer(ctx)
      pointer:withdraw()
      local board: keyboard.Keyboard = keys:new(ctx, {
        target = function()
          return focused:focused()
        end,
      })
      board:typeText(config.title)
      board:setSize(nil, config.height)
      dropped:onDropped(ctx, {
        run = function(drop: drops.Drop)
          local surface = drop.surface
          if surface.kind == 'window' then
            local panel = panelRegistry:forSource(surface.source)
            if panel then
              panel:setSize(nil, config.height)
            end
          end
          drop.pointer:withdraw()
          board:setVisible(true)
        end,
      })
      local allPanels: { panels.Panel } = panelRegistry:all()
      for _, panel in allPanels do
        if panel.kind == 'window' then
          local windowTitle: string = panel.source.title or 'untitled'
          board:typeText(windowTitle)
        end
      end
    end,
  }
  local runtime = api.runtime()
  local providerInstance = runtime:use(provider, { title = 'fixture', height = 1 })
  local consumerInstance = runtime:use(consumer, { title = 'fixture', height = 1 })
  consumerInstance:reload { title = 'reload', height = 2 }
  return { provider = providerInstance, consumer = consumerInstance, runtime = runtime }
end

return build
