-- Arranges unposed placements unless the user has dropped them or they carry a persisted pose.
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local layouts = require '@lunette-contracts/layouts'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local tags = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local logging = require '@lunette-plugins/desktop/logging'

local config = require '@lunette-plugins/desktop/arrange/config'

export type Config = config.Config
export type Settings = config.Settings

local UPDATE_ORDER = -10

local required: plugin.Declaration = {
  drops = drops.capability,
  frame = frame.capability,
  layouts = layouts.capability,
  panels = panels.capability,
  placement = placement.capability,
  tags = tags.capability,
}

-- A persisted window pose records a user-selected placement.
local function kept(panel: panels.WindowPanel): boolean
  local source = panel.source
  return not source.dead and type(source:getProperty(vocabulary.POSE_PROPERTY)) == 'string'
end

type Plan = { tag: tags.Tag, layout: string, options: { read [string]: unknown }? }

local function define(): plugin.Definition<Config>
  -- Dropped panels stay excluded while they remain live.
  local dropped: { [panels.Panel]: boolean } = setmetatable({} :: { [panels.Panel]: boolean }, { __mode = 'k' })
  return plugin.consumer<<Config, Settings>>({
    name = 'desktop/arrange',
    requires = required,
    schema = config.schema,
    init = function(context: plugin.Context, settings: Settings): ()
      local dropService: drops.Service = context:require(drops.capability)
      local frameService: frame.Service = context:require(frame.capability)
      local layoutService: layouts.Service = context:require(layouts.capability)
      local panelService: panels.Service = context:require(panels.capability)
      local placementService: placement.Service = context:require(placement.capability)
      local tagService: tags.Service = context:require(tags.capability)

      local function chosen(): { tags.Tag }
        if #settings.tags == 0 then
          return tagService:all()
        end
        local result: { tags.Tag } = {}
        for _, name in settings.tags do
          local tag = tagService:find(name)
          if tag then
            result[#result + 1] = tag
          end
        end
        return result
      end

      local function candidates(): { panels.WindowPanel }
        local result: { panels.WindowPanel } = {}
        for _, placed in ipairs(placementService:placed()) do
          local panel = placed.panel
          if placed.properties.pose == nil and not dropped[panel] and not panel.dead and not kept(panel) then
            result[#result + 1] = panel
          end
        end
        return result
      end

      local function plans(): { Plan }
        local selected: { Plan } = {}
        local rest: { Plan } = {}
        for _, tag in ipairs(chosen()) do
          local layout = tag.layout or settings.layout
          local plan: Plan = { tag = tag, layout = layout, options = settings.options[layout] }
          local group = if tag.selected then selected else rest
          group[#group + 1] = plan
        end
        table.move(rest, 1, #rest, #selected + 1, selected)
        return selected
      end

      local function arrange(): ()
        local waiting = candidates()
        local done: { [panels.Panel]: boolean } = {}
        for _, plan in ipairs(plans()) do
          local members: { layouts.Panel } = {}
          for _, panel in ipairs(waiting) do
            if not done[panel] and plan.tag:has(panel) then
              members[#members + 1] = panel
              done[panel] = true
            end
          end
          if layoutService:get(plan.layout) ~= nil then
            layoutService:apply { name = plan.layout, panels = members, options = plan.options }
          end
        end
      end

      -- A drop of a surface that stands for a panel, such as a title bar, is a drop of that panel.
      dropService:onDropped(context, {
        run = function(drop: drops.Drop)
          local surface = drop.surface
          if surface.kind == 'window' or surface.kind == 'monitor' then
            local panel = panelService:forSource(surface.source)
            if panel then
              dropped[panel] = true
            end
          end
        end,
      })
      panelService:onRemoved(context, { run = arrange })
      placementService:onPlaced(context, { run = arrange })
      layoutService:onChanged(context, { run = arrange })
      tagService:onChanged(context, { run = arrange })
      local reported: { [string]: boolean } = {}
      frameService:onUpdate(context, {
        phase = 'scene',
        order = UPDATE_ORDER,
        run = function(): ()
          local continuous = false
          local used: { string } = { settings.layout }
          for _, plan in ipairs(plans()) do
            used[#used + 1] = plan.layout
          end
          for _, name in ipairs(used) do
            local entry = layoutService:get(name)
            if entry == nil and not reported[name] then
              reported[name] = true
              local names = layoutService:names()
              local known = if #names == 0
                then 'no layout is registered'
                else 'the registered layouts are ' .. table.concat(names, ', ')
              logging.report('desktop/arrange: ' .. name .. ' is not a registered layout; ' .. known, 'warn')
            elseif entry and entry.continuous then
              continuous = true
            end
          end
          if continuous then
            arrange()
          end
        end,
      })
      arrange()
    end,
  }).definition
end

return define
