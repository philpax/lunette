-- The arrangement of placed windows that no rule or saved state placed.
--
-- The module is a definition factory. The arranged windows are every live
-- placement made without a pose, less every window the user has put
-- somewhere: one dropped while this consumer was active, and one whose kept
-- pose, the `lunette.pose` property desktop/pose-memory writes on a drop, is
-- set. A window put somewhere stays there, and a later arrangement does not
-- move it back, even when it was dropped while this consumer was unloaded.
-- The panels dropped while active are remembered outside any activation, so
-- an outage of this consumer does not return them to the set either.
--
-- The windows are arranged tag by tag: each tag `tags` names, every tag when
-- it is empty, poses its arranged members that an earlier tag has not, in the
-- order they were placed. The selected tags come first, then the rest, each
-- group in the tags service's order, so a window in several tags is arranged
-- by the first selected tag that holds it, and by the first tag that holds it
-- when none of its tags is selected: a window on every workspace is laid out
-- with the workspace in view. A tag is posed with its own layout when it
-- names one, and otherwise with `layout`. `options` are keyed by layout name,
-- and a layout is applied with its own entry, whichever tag uses it, or with
-- none; each replaces the layout's defaults wholesale, and the layout
-- validates it.
-- The set is arranged when the consumer activates, when a window is placed,
-- when a panel is removed, when a layout is registered or unregistered, and
-- when a tag is made, ends, changes its selection, changes its layout, or
-- changes its members. A
-- continuous layout in use is also applied on every frame update, in the
-- scene phase before the panels update. A layout name that is not
-- registered is reported once, on the first frame that finds it missing,
-- and its tag is arranged as soon as it registers.
local plugin = require '@lunette-plugin'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local layouts = require '@lunette-contracts/layouts'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local tags = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local logging = require '@lunette-desktop/logging'

-- What a configuration gives: every option optional.
export type Config = {
  read layout: string?,
  read options: { read [string]: { read [string]: unknown } }?,
  read tags: { string }?,
}

export type Settings = {
  read layout: string,
  read options: { read [string]: { read [string]: unknown } },
  read tags: { string },
}

local DEFAULTS: Settings = { layout = 'arc', options = {}, tags = {} }

-- Before the panels update in the scene phase, so a continuous layout's poses
-- are the ones this frame draws.
local UPDATE_ORDER = -10

local required: plugin.Declaration = {
  drops = drops.capability,
  frame = frame.capability,
  layouts = layouts.capability,
  panels = panels.capability,
  placement = placement.capability,
  tags = tags.capability,
}

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/arrange', defaults = DEFAULTS, config = config }
  if settings.layout == '' then
    error('plugin desktop/arrange: option layout is a non-empty layout name', 0)
  end
  for name, options in settings.options do
    if type(name) ~= 'string' or name == '' then
      error('plugin desktop/arrange: option options is keyed by layout name, not by ' .. tostring(name), 0)
    end
    if type(options) ~= 'table' then
      error(
        string.format('plugin desktop/arrange: option options.%s is a table of options, not a %s', name, type(options)),
        0
      )
    end
  end
  for index, name in ipairs(settings.tags) do
    if type(name) ~= 'string' or name == '' then
      error(string.format('plugin desktop/arrange: option tags[%d] is a non-empty tag name', index), 0)
    end
  end
  return settings
end

-- Whether a window has a kept pose: the user put it somewhere.
local function kept(panel: panels.WindowPanel): boolean
  local source = panel.source
  return not source.dead and type(source:getProperty(vocabulary.POSE_PROPERTY)) == 'string'
end

-- Each tag to arrange, with the layout and options it is posed with.
type Plan = { tag: tags.Tag, layout: string, options: { read [string]: unknown }? }

local function define(): plugin.Definition<Config>
  -- Weak keys, so a panel that has ended is not retained by having been
  -- dropped once.
  local dropped: { [panels.Panel]: boolean } = setmetatable({} :: { [panels.Panel]: boolean }, { __mode = 'k' })
  return plugin.define {
    name = 'desktop/arrange',
    requires = required,
    init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
      local settings = resolve(config)
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
        for _, name in ipairs(settings.tags) do
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

      -- A drop of a surface that stands for a panel, such as a title bar, is a
      -- drop of that panel.
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
      panelService:onRemoved(context, {
        run = function()
          arrange()
        end,
      })
      placementService:onPlaced(context, {
        run = function()
          arrange()
        end,
      })
      layoutService:onChanged(context, {
        run = function()
          arrange()
        end,
      })
      tagService:onChanged(context, {
        run = function(_change: tags.Change)
          arrange()
        end,
      })
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
  }
end

return define
