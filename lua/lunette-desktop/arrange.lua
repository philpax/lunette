-- The arrangement of adopted windows that no rule or saved state placed.
--
-- The module is a definition factory. The arranged set is every live
-- adoption placed without a pose that belongs to the tag named `tag`, in the
-- order the windows were placed, less every panel the user has dropped: a
-- dropped panel stays where it was dropped, and a later arrangement does not
-- move it back. The panels dropped are remembered outside any activation, so
-- an outage of this consumer does not return them to the set.
--
-- `layout` names the layout in the layouts broker the set is posed with, and
-- `options` are that layout's own options, which replace the default
-- wholesale and which the layout validates. The set is arranged when the
-- consumer activates, when a window is placed, when a panel is removed, and
-- when a layout is registered or unregistered. A continuous layout is also
-- applied on every frame update, in the scene phase before the panels update.
-- When the first frame after activation finds no layout registered under
-- `layout`, the consumer reports it once, and it arranges as soon as one is.
local plugin = require '@lunette-plugin'
local adoption = require '@lunette-contracts/adoption'
local frame = require '@lunette-contracts/frame'
local layouts = require '@lunette-contracts/layouts'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'
local logging = require '@lunette-desktop/logging'

-- What a configuration gives: every option optional.
export type Config = {
  read layout: string?,
  read options: { [string]: unknown }?,
  read tag: string?,
}

export type Settings = {
  read layout: string,
  read options: { [string]: unknown },
  read tag: string,
}

local DEFAULTS: Settings = { layout = 'arc', options = {}, tag = 'main' }

-- Before the panels update in the scene phase, so a continuous layout's poses
-- are the ones this frame draws.
local UPDATE_ORDER = -10

local required: plugin.Declaration = {
  adoption = adoption.capability,
  frame = frame.capability,
  layouts = layouts.capability,
  panels = panels.capability,
  tags = tags.capability,
}

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/arrange', defaults = DEFAULTS, config = config }
  if settings.layout == '' then
    error('plugin desktop/arrange: option layout is a non-empty layout name', 0)
  end
  if settings.tag == '' then
    error('plugin desktop/arrange: option tag is a non-empty tag name', 0)
  end
  return settings
end

local function define(): plugin.Definition<Config>
  -- Weak keys, so a panel that has ended is not retained by having been
  -- dropped once.
  local dropped: { [panels.Panel]: boolean } = setmetatable({} :: { [panels.Panel]: boolean }, { __mode = 'k' })
  return plugin.define {
    name = 'desktop/arrange',
    requires = required,
    init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
      local settings = resolve(config)
      local adoptionService: adoption.Service = context:require(adoption.capability)
      local frameService: frame.Service = context:require(frame.capability)
      local layoutService: layouts.Service = context:require(layouts.capability)
      local panelService: panels.Service = context:require(panels.capability)
      local tagService: tags.Service = context:require(tags.capability)

      local function arranged(): { layouts.Panel }
        local result: { layouts.Panel } = {}
        local tag = tagService:find(settings.tag)
        if not tag then
          return result
        end
        for _, placement in ipairs(adoptionService:placed()) do
          local panel = placement.panel
          if placement.properties.pose == nil and not dropped[panel] and not panel.dead and tag:has(panel) then
            result[#result + 1] = panel
          end
        end
        return result
      end

      local function arrange(): ()
        if layoutService:get(settings.layout) == nil then
          return
        end
        layoutService:apply { name = settings.layout, panels = arranged(), options = settings.options }
      end

      panelService:onDropped(context, {
        run = function(panel: panels.Panel)
          dropped[panel] = true
        end,
      })
      panelService:onRemoved(context, {
        run = function()
          arrange()
        end,
      })
      adoptionService:onPlaced(context, {
        run = function()
          arrange()
        end,
      })
      layoutService:onChanged(context, {
        run = function()
          arrange()
        end,
      })
      local checked = false
      frameService:onUpdate(context, {
        phase = 'scene',
        order = UPDATE_ORDER,
        run = function(): ()
          local entry = layoutService:get(settings.layout)
          if not checked then
            checked = true
            if entry == nil then
              local names = layoutService:names()
              local known = if #names == 0
                then 'no layout is registered'
                else 'the registered layouts are ' .. table.concat(names, ', ')
              logging.report('desktop/arrange: ' .. settings.layout .. ' is not a registered layout; ' .. known, 'warn')
            end
          end
          if entry and entry.continuous then
            arrange()
          end
        end,
      })
      arrange()
    end,
  }
end

return define
