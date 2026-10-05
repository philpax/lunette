-- Hides panels in unselected workspace tags with an override, preserving higher-priority visibility decisions. The follow option moves newly placed panels into the selected workspace.
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local tags = require '@lunette-contracts/tags'

local config = require '@lunette-plugins/desktop/workspaces/config'
local schema = require '@lunette-plugin/schema'

local childSchema = schema.object {}
type ChildConfig = schema.Input<typeof(childSchema)>
type ChildSettings = schema.Output<typeof(childSchema)>

export type Workspace = config.Workspace
export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  panels = panels.capability,
  placement = placement.capability,
  tags = tags.capability,
}

-- Key bindings run as a child so a bindings outage does not change workspace selection.
local function chords(settings: Settings, switch: (number) -> ()): plugin.Definition<ChildConfig>
  return plugin.consumer<<ChildConfig, ChildSettings>>({
    name = 'desktop/workspaces/chords',
    requires = { bindings = bindings.capability },
    schema = childSchema,
    init = function(context: plugin.Context, _settings: ChildSettings): ()
      local service: bindings.Service = context:require(bindings.capability)
      for index, workspace in settings.workspaces do
        service:register(context, {
          chord = { key = workspace.key, modifiers = settings.modifiers },
          run = function(_press: bindings.Press): ()
            switch(index)
          end,
        })
      end
    end,
  }).definition
end

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/workspaces',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local panelService: panels.Service = context:require(panels.capability)
    local placementService: placement.Service = context:require(placement.capability)
    local tagService: tags.Service = context:require(tags.capability)

    local held: { tags.Tag } = {}
    local isWorkspace: { [tags.Tag]: boolean } = {}
    for index, workspace in settings.workspaces do
      local tag = tagService:hold(context, { name = workspace.name, index = index })
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
          hiding[panel] = real:setHidden(context, { hidden = true })
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
      current = index
      for position, tag in ipairs(held) do
        tag:setSelected(context, { selected = position == index })
      end
      refresh()
    end

    tagService:onChanged(context, {
      run = function(change: tags.Change): ()
        if isWorkspace[change.tag] and (change.kind == 'membership' or change.kind == 'selection') then
          refresh()
        end
      end,
    })
    panelService:onRemoved(context, {
      run = function(panel: panels.Panel): ()
        hiding[panel :: any] = nil
      end,
    })
    if settings.follow then
      placementService:onPlaced(context, {
        run = function(placed: placement.Placement): ()
          local panel = placed.panel
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
          if not inWorkspace or shown.dead then
            return
          end
          for _, tag in ipairs(held) do
            if tag:has(panel) then
              tag:exclude(context, { panel = panel })
            end
          end
          shown:add(context, panel)
        end,
      })
    end
    switch(current)
    context:child(chords(settings, switch), {})
  end,
}).definition
