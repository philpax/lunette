-- Holds the workspace tags, selects one, and hides panels in unselected workspaces with an override that preserves higher-priority visibility decisions. A newly placed panel in no workspace joins the selected one, and the follow option also moves newly placed panels from other workspaces into it.
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local tags = require '@lunette-contracts/tags'

local config = require '@self/config'

type ChildConfig = {}
type ChildSettings = {}

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  panels.capability,
  placement.capability,
  tags.capability,
}

-- Actions run as a child so a menu outage does not change workspace selection or follow.
local function actions(settings: Settings, held: { tags.Tag }, switch: (number) -> ()): plugin.Definition<ChildConfig>
  return plugin.consumer<<ChildConfig, ChildSettings>>({
    name = 'desktop/workspaces/actions',
    requires = { menu.capability, tags.capability },
    init = function(context: plugin.Context, _settings: ChildSettings): ()
      local service: menu.Service = context:require(menu.capability)
      local tagService: tags.Service = context:require(tags.capability)
      local registrations: { [tags.Tag]: menu.Registration } = {}
      for index, name in settings.names do
        local tag = held[index]
        registrations[tag] = service:register(context, {
          id = 'desktop/workspace/' .. name,
          label = name,
          group = 'Workspaces',
          selected = tag.selected,
          run = function(): ()
            if context:active() then
              switch(index)
            end
          end,
        })
      end
      tagService:onChanged(context, {
        run = function(change: tags.Change): ()
          local registration = registrations[change.tag]
          if context:active() and registration and change.kind == 'selection' then
            registration:update { selected = change.tag.selected }
          end
        end,
      })
    end,
  }).definition
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/workspaces',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local panelService: panels.Service = context:require(panels.capability)
    local placementService: placement.Service = context:require(placement.capability)
    local tagService: tags.Service = context:require(tags.capability)

    local held: { tags.Tag } = {}
    local isWorkspace: { [tags.Tag]: boolean } = {}
    for index, name in settings.names do
      local tag = tagService:hold(context, { name = name, index = index })
      held[index] = tag
      isWorkspace[tag] = true
    end
    -- Each panel this consumer hides, with the override that hides it.
    local hiding: { [tags.Panel]: plugin.Effect } = {}

    local function refresh(): ()
      local wanted: { [tags.Panel]: boolean } = {}
      for _, tag in ipairs(held) do
        for _, panel in ipairs(tag:panels()) do
          if tag.selected then
            wanted[panel] = false
          elseif wanted[panel] == nil then
            wanted[panel] = true
          end
        end
      end
      for panel, effect in pairs(hiding) do
        if not wanted[panel] then
          hiding[panel] = nil
          effect:dispose()
        end
      end
      for panel, hide in pairs(wanted) do
        if hide and not hiding[panel] and not panel.dead then
          -- The tags contract exposes members as surfaces.
          local real = (panel :: any) :: panels.Panel
          hiding[panel] = real:setHidden(context, true)
        end
      end
    end

    local current = 1
    for index, tag in ipairs(held) do
      if tag.selected then
        current = index
        break
      end
    end
    local function switch(index: number): ()
      if not context:active() then
        return
      end
      current = index
      for position, tag in ipairs(held) do
        tag:setSelected(context, position == index)
      end
      refresh()
    end

    tagService:onChanged(context, {
      run = function(change: tags.Change): ()
        if isWorkspace[change.tag] and (change.kind == 'membership' or change.kind == 'selection') then
          if change.kind == 'selection' then
            if change.tag.selected then
              current = table.find(held, change.tag) or current
            elseif not held[current].selected then
              for index, tag in held do
                if tag.selected then
                  current = index
                  break
                end
              end
            end
          end
          refresh()
        end
      end,
    })
    panelService:onRemoved(context, {
      run = function(panel: panels.Panel): ()
        hiding[panel :: any] = nil
      end,
    })
    -- A placed panel in no workspace joins the selected one, whatever configured adoption. Following also moves a
    -- placed panel out of an unselected workspace.
    local function join(panel: panels.WindowPanel, follow: boolean): ()
      local shown = held[current]
      local inWorkspace = false
      for _, tag in ipairs(held) do
        if tag:has(panel) then
          if tag.selected then
            return
          end
          inWorkspace = true
        end
      end
      if panel.dead or shown.dead or (inWorkspace and not follow) then
        return
      end
      for _, tag in ipairs(held) do
        if tag:has(panel) then
          tag:exclude(context, panel)
        end
      end
      shown:add(context, panel)
    end
    -- Panels placed before this activation, such as during an outage, join without following.
    for _, placed in ipairs(placementService:placed()) do
      join(placed.panel, false)
    end
    placementService:onPlaced(context, {
      run = function(placed: placement.Placement): ()
        join(placed.panel, settings.follow)
      end,
    })
    switch(current)
    -- One workspace has nothing to switch to.
    if #held > 1 then
      context:child(actions(settings, held, switch))
    end
  end,
}
