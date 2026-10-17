-- The Configure tab: draft actions, the option rows, and the value editor for the selected row.

local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local composition = require '@lunette-contracts/composition'
local pluginManager = require '@lunette-contracts/plugin-manager'
local controller = require '../composition/controller'
local editor = require '../composition/editor'
local model = require './model'

local configure = {}

-- A row's item id: its path, with the type of each part, so string and number keys stay distinct.
function configure.rowId(path: editor.Path): string
  local parts = { 'row' }
  for _, part in path do
    local value = tostring(part):gsub('%%', '%%25'):gsub('/', '%%2f')
    parts[#parts + 1] = (if type(part) == 'number' then 'n:' else 's:') .. value
  end
  return table.concat(parts, '/')
end

local function equal(left: unknown, right: unknown): boolean
  if left == right then
    return true
  end
  if type(left) ~= 'table' or type(right) ~= 'table' then
    return false
  end
  local a, b = left :: { [unknown]: unknown }, right :: { [unknown]: unknown }
  for key, value in a do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in b do
    if a[key] == nil then
      return false
    end
  end
  return true
end

-- The text field and its Confirm, Cancel, and Clear actions while an option's text is edited.
local TextEdit = ui.component('PluginTextEdit', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local field = ui.useRef(nil :: uiHost.Node?)
  local edit = state.edit
  local identity = if edit then `{state.draftEntry}/{edit.operation}/{configure.rowId(edit.path)}` else ''
  -- A new edit starts from the option's text and takes the keyboard, and the end of the edit returns it.
  ui.useEffect(function(): (() -> ())?
    local node = field.current
    if node and not node.dead then
      m.focusField(node)
    end
    return m.releaseField
  end, { identity })
  return c.Column {
    key = 'text',
    gap = 'sm',
    c.TextField {
      key = 'edit-field',
      ref = field,
      value = state.text,
      placeholder = if edit and edit.operation == 'add' then 'Map key' else 'Value',
      onChange = function(text: string): ()
        m.change(function(): ()
          controller.setText(state, text)
        end)
      end,
      onSubmit = function(text: string): ()
        m.change(function(): ()
          controller.setText(state, text)
          controller.confirmText(state)
        end)
      end,
      onCancel = function(_text: string): ()
        m.change(function(): ()
          controller.cancelText(state)
        end)
      end,
    },
    c.Row {
      key = 'edit-actions',
      gap = 'sm',
      model.button(c, m, 'confirm', { variant = 'primary', grow = 1 }),
      model.button(c, m, 'cancel', { grow = 1 }),
      c.Button {
        key = 'clear',
        label = 'Clear',
        grow = 1,
        onActivate = function(): ()
          m.invoke 'clear'
        end,
      },
    },
  }
end)

-- The value editor for the selected row: a toggle, a choice, or the text edit.
local function valueEditor(c: uiComponents.Service, m: model.Model): ui.Child
  local state = m.state
  if state.edit then
    return TextEdit { key = 'text' }
  end
  local index = state.row
  local row = if index then state.editorRows[index] else nil
  if not index or not row or row.readOnly then
    return nil
  end
  if row.control == 'boolean' then
    return c.Toggle {
      key = 'boolean-field',
      label = row.label,
      value = row.value == true,
      onChange = function(_value: boolean): ()
        m.change(function(): ()
          controller.toggle(state)
        end)
      end,
    }
  elseif row.control == 'choice' and row.choices then
    local options = {}
    local selected: string? = nil
    for choiceIndex, value in row.choices do
      options[choiceIndex] = { id = tostring(choiceIndex), label = tostring(value) }
      if equal(value, row.value) then
        selected = tostring(choiceIndex)
      end
    end
    return c.Dropdown {
      key = 'choice-field',
      options = options,
      value = selected,
      onChange = function(id: string): ()
        local choice = tonumber(id)
        if choice then
          m.change(function(): ()
            controller.choose(state, index, choice)
          end)
        end
      end,
    }
  end
  return nil
end

-- The metres a plugin's settings page may take below the options before it is clipped.
local SETTINGS_HEIGHT = 0.2

-- The settings pages that plugins contribute for the selected entry, in the manager's attributed outlet.
local function settingsPages(c: uiComponents.Service, entry: composition.Entry?): ui.Child
  local id = if entry then entry.id else ''
  local name = if entry then entry.name else ''
  local props = ui.useMemo(function(): pluginManager.SettingsProps
    return { entry = id, name = name }
  end, { id, name })
  if not entry then
    return nil
  end
  return c.Outlet { key = 'settings', outlet = pluginManager.settings, props = props, maxHeight = SETTINGS_HEIGHT }
end

configure.Configure = ui.component('PluginConfigure', function(): ui.Child
  local c = ui.useComponents()
  local m = model.use()
  local state = m.state
  local entry = controller.selected(state)
  local pages = settingsPages(c, entry)
  local saved = entry and entry.saved
  local base = (if entry and type(entry.baseConfig) == 'table' then entry.baseConfig else {}) :: { [string]: unknown }
  local items = {}
  for _, row in state.editorRows do
    local field = if #row.path == 1 then row.path[1] else nil
    -- A saved option says so, with the value main.luau gives it, so a stale saved value is easy to find and forget.
    local isSaved = type(field) == 'string' and saved ~= nil and saved[field] ~= nil
    local detail = if row.readOnly then row.reason else row.description
    if isSaved then
      local configured = `Saved; main.luau: {controller.valueText(base[field :: string])}`
      detail = if detail then `{configured}. {detail}` else configured
    end
    items[#items + 1] = {
      id = configure.rowId(row.path),
      title = if isSaved then `{row.label} *` else row.label,
      detail = detail,
      trailing = if row.text == '' then '(empty)' else row.text,
    }
  end
  local selected = if state.row then state.editorRows[state.row] else nil
  return c.Column {
    key = 'configure',
    grow = 1,
    height = 0,
    gap = 'sm',
    c.Row {
      key = 'draft',
      gap = 'sm',
      wrap = true,
      model.button(c, m, 'apply', { variant = 'primary' }),
      model.button(c, m, 'optional'),
      model.button(c, m, 'reset'),
      model.button(c, m, 'add'),
      model.button(c, m, 'remove-value'),
      model.button(c, m, 'forget-saved'),
      model.button(c, m, 'forget-entry'),
    },
    c.ScrollView {
      key = 'rows-box',
      grow = 1,
      c.List {
        key = 'rows',
        items = items,
        value = if selected then configure.rowId(selected.path) else nil,
        onChange = function(id: string): ()
          for index, row in state.editorRows do
            if configure.rowId(row.path) == id then
              m.change(function(): ()
                controller.selectRow(state, index)
              end)
              return
            end
          end
        end,
      },
    },
    valueEditor(c, m),
    pages,
  }
end)

return configure
