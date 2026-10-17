-- The sidebar: the Inspect, Configure, Catalog, and Saved tabs, the lifecycle actions, and the selected tab's content.

local ui = require '@lunette-plugins/ui/react'
local uiComponents = require '@lunette-contracts/ui-components'
local controller = require '../composition/controller'
local model = require './model'
local configure = require './configure'

local sidebar = {}

local function details(c: uiComponents.Service, lines: { string }): ui.Child
  local texts = {}
  for index, line in lines do
    texts[index] = c.Text { key = `line-{index}`, text = line, style = 'caption' }
  end
  return c.ScrollView { key = 'details', grow = 1, c.Column { key = 'lines', gap = 'xs', texts } }
end

local function catalog(c: uiComponents.Service, m: model.Model): ui.Child
  local state = m.state
  local items = {}
  for _, known in state.catalog do
    items[#items + 1] = {
      id = known.id,
      title = known.id,
      trailing = if known.installed then 'installed' else 'removed',
    }
  end
  local captions = {}
  for index, line in state.details do
    captions[index] = c.Text { key = `line-{index}`, text = line, style = 'caption', color = 'muted' }
  end
  return c.Column {
    key = 'catalog',
    grow = 1,
    height = 0,
    gap = 'sm',
    c.Row { key = 'catalog-actions', gap = 'sm', model.button(c, m, 'load', { variant = 'primary' }) },
    captions,
    c.ScrollView {
      key = 'catalog-box',
      grow = 1,
      c.List {
        key = 'catalog-list',
        items = items,
        value = state.catalogSelection,
        onChange = function(id: string): ()
          m.change(function(): ()
            controller.selectCatalog(state, id)
          end)
        end,
      },
    },
  }
end

-- Every saved setting, as a registry editor lists keys: by entry and field, with the value and whether it applies.
local STATUS: { [string]: string } = {
  applied = 'Applies',
  invalid = 'Does not fit the entry',
  suspended = 'Suspended: the entry failed to start with it',
  unused = 'The entry is not composed',
}

local function savedPage(c: uiComponents.Service, m: model.Model): ui.Child
  local state = m.state
  local items = {}
  for _, setting in state.savedSettings do
    local status = STATUS[setting.status] or setting.status
    items[#items + 1] = {
      id = `{setting.id}/{setting.field}`,
      title = `{setting.id} {setting.field}`,
      detail = if setting.problem then `{status}: {setting.problem}` else status,
      trailing = controller.valueText(setting.value),
    }
  end
  local chosen = state.savedSelection
  return c.Column {
    key = 'saved',
    grow = 1,
    height = 0,
    gap = 'sm',
    c.Row {
      key = 'saved-actions',
      gap = 'sm',
      model.button(c, m, 'forget-selected', { variant = 'primary' }),
      model.button(c, m, 'forget-everything', { variant = 'danger' }),
    },
    if #items == 0
      then c.Text { key = 'empty', text = 'No settings are saved.', style = 'caption', color = 'muted' }
      else nil,
    c.ScrollView {
      key = 'saved-box',
      grow = 1,
      c.List {
        key = 'saved-list',
        items = items,
        value = if chosen then `{chosen.id}/{chosen.field}` else nil,
        onChange = function(key: string): ()
          for _, setting in state.savedSettings do
            if `{setting.id}/{setting.field}` == key then
              m.change(function(): ()
                controller.selectSaved(state, setting.id, setting.field)
              end)
              return
            end
          end
        end,
      },
    },
  }
end

sidebar.Sidebar = ui.component('PluginSidebar', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local content: ui.Child
  if state.tab == 'catalog' then
    content = catalog(c, m)
  elseif state.tab == 'saved' then
    content = savedPage(c, m)
  elseif state.tab == 'configure' and state.draft then
    content = configure.Configure { key = 'configure' }
  else
    content = details(c, state.details)
  end
  return c.Column {
    key = 'sidebar',
    width = m.sidebarWidth,
    shrink = 0,
    gap = 'sm',
    c.Segmented {
      key = 'tabs',
      options = model.options(m, { 'inspect', 'configure', 'catalog', 'saved' }),
      value = state.tab,
      onChange = m.invoke,
    },
    c.Row {
      key = 'lifecycle',
      gap = 'sm',
      wrap = true,
      model.button(c, m, 'enable'),
      model.button(c, m, 'disable'),
      model.button(c, m, 'reload'),
      model.button(c, m, 'recover'),
      model.button(c, m, 'remove'),
    },
    c.Separator { key = 'rule' },
    content,
  }
end)

return sidebar
