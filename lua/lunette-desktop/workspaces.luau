-- Workspaces: one tag shown at a time, switched with key chords.
--
-- Shipped but not in the default entries; a configuration adds it with
-- `{ insert = { id = 'desktop/workspaces', definition = require '@lunette-desktop/workspaces' } }`.
--
-- `workspaces` is the list of workspaces, each `{ name, key }`: the tag it
-- shows and the key that selects it, held with `modifiers`. The consumer
-- holds every workspace's tag and selects one, the first that is already
-- selected or else the first in the list. A panel that is a member of some
-- workspace's tag and of no selected one is hidden through its visibility
-- override, which the consumer withdraws rather than overrides when the
-- panel is to be shown, so a panel another plugin hid stays hidden. A panel
-- in no workspace's tag is left alone. With `follow`, a window placed into
-- workspaces none of which is shown leaves them for the shown one, so a
-- window opens where the user is; a window a rule placed in another
-- workspace then follows too, so a configuration that places windows by
-- workspace turns `follow` off.
--
-- The chords are a child plugin, so an outage of the bindings provider
-- leaves the workspaces as they are rather than showing every panel.
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local tags = require '@lunette-contracts/tags'

export type Workspace = {
  read name: string,
  read key: KeyCode,
}

-- What a configuration gives: every option optional.
export type Config = {
  read workspaces: { Workspace }?,
  read modifiers: { string }?,
  read follow: boolean?,
}

export type Settings = {
  read workspaces: { Workspace },
  read modifiers: { string },
  read follow: boolean,
}

local DEFAULTS: Settings = {
  workspaces = {
    { name = 'main', key = '1' },
    { name = 'two', key = '2' },
    { name = 'three', key = '3' },
    { name = 'four', key = '4' },
  },
  modifiers = { 'logo' },
  follow = true,
}

local required: plugin.Declaration = {
  panels = panels.capability,
  placement = placement.capability,
  tags = tags.capability,
}

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/workspaces', defaults = DEFAULTS, config = config }
  if #settings.workspaces == 0 then
    error('plugin desktop/workspaces: option workspaces names at least one workspace', 0)
  end
  local seen: { [string]: boolean } = {}
  for index, workspace in ipairs(settings.workspaces) do
    local where = string.format('plugin desktop/workspaces: option workspaces[%d]', index)
    if type(workspace) ~= 'table' then
      error(where .. ' is a table of name and key', 0)
    end
    for key, _ in workspace :: { [unknown]: unknown } do
      if key ~= 'name' and key ~= 'key' then
        error(where .. ' has an unknown field ' .. tostring(key) .. '; the fields are name and key', 0)
      end
    end
    if type(workspace.name) ~= 'string' or workspace.name == '' then
      error(where .. '.name is a non-empty tag name', 0)
    end
    if seen[workspace.name] then
      error(where .. '.name names ' .. workspace.name .. ' twice', 0)
    end
    seen[workspace.name] = true
    if type(workspace.key) ~= 'string' or workspace.key == '' then
      error(where .. '.key is a key name', 0)
    end
  end
  return settings
end

-- The chords, as a child, so a bindings outage leaves the workspaces alone.
local function chords(settings: Settings, switch: (number) -> ()): plugin.Definition<{}>
  return plugin.define {
    name = 'desktop/workspaces/chords',
    requires = { bindings = bindings.capability },
    init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher): ()
      local service: bindings.Service = context:require(bindings.capability)
      for index, workspace in ipairs(settings.workspaces) do
        service:register(context, {
          chord = { key = workspace.key, modifiers = settings.modifiers },
          run = function(_press: bindings.Press): ()
            switch(index)
          end,
        })
      end
    end,
  }
end

return plugin.define {
  name = 'desktop/workspaces',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings = resolve(config)
    local panelService: panels.Service = context:require(panels.capability)
    local placementService: placement.Service = context:require(placement.capability)
    local tagService: tags.Service = context:require(tags.capability)

    local held: { tags.Tag } = {}
    local isWorkspace: { [tags.Tag]: boolean } = {}
    for index, workspace in ipairs(settings.workspaces) do
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
          -- A tag's members are the panels the panels provider made, which
          -- the tags contract types only as surfaces.
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
}
