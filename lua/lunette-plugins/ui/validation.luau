-- Public UI inputs are validated and copied before callbacks or owned resources are acquired.
local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local geometry = require './geometry'
local theme = require './theme'
local titlebarOptions = require './titlebar-options'

local validation = {}
local copyControl: <T>(T, { string }, string) -> T
local callback: (unknown, string, boolean?) -> ()
local optional: <T>(schema.Schema<T, T>, unknown, string) -> ()

local COMMON: { string } = { 'id', 'owner', 'bounds', 'label', 'enabled', 'z', 'theme', 'draw' }
local function controlFields(...: string): { string }
  local result = table.clone(COMMON)
  for _, field in { ... } do
    table.insert(result, field)
  end
  return result
end
local BUTTON = controlFields 'onActivate'
local TEXT = controlFields('value', 'onChange', 'onSubmit', 'onCancel')
local CHOICE = controlFields('items', 'selected', 'onChange')
local REGION = controlFields('items', 'onPointer', 'receiver', 'wantsKeyboard')
local PANEL: { string } = {
  'name',
  'pose',
  'width',
  'height',
  'logicalWidth',
  'logicalHeight',
  'visible',
  'grabbable',
  'grabTarget',
  'titlebar',
  'theme',
  'draw',
}
local RECEIVER: { string } = { 'key', 'text', 'onFocus', 'onBlur' }
local stringValue = schema.string()
local identifier = schema.string { minLength = 1 }
local booleanValue = schema.boolean()
local numberValue = schema.number()
local boundsValue = schema.object {
  x = schema.number(),
  y = schema.number(),
  width = schema.number { minimum = 0 },
  height = schema.number { minimum = 0 },
}
local routeValue = schema.array(schema.object { x = schema.number(), y = schema.number() })
local regionItems = schema.array(schema.object {
  id = identifier,
  label = schema.optional(stringValue),
  bounds = boundsValue,
  route = schema.optional(routeValue),
})
local collectionItems = schema.array(schema.object {
  id = identifier,
  label = stringValue,
  enabled = schema.optional(booleanValue),
})

function validation.panel(options: ui.PanelOptions): ui.PanelOptions
  assert(type(options) == 'table' and getmetatable(options) == nil, 'ui panel: options are a plain table')
  plugin.rejectUnknownFields('ui panel', options, PANEL, 3)
  identifier.parse(options.name, 'ui panel name')
  local dimensions: { [string]: unknown } = {
    width = options.width,
    height = options.height,
    logicalWidth = options.logicalWidth,
    logicalHeight = options.logicalHeight,
  }
  for _, label in { 'width', 'height', 'logicalWidth', 'logicalHeight' } do
    local value = numberValue.parse(dimensions[label], 'ui panel ' .. label)
    geometry.positive(value, label)
  end
  optional(booleanValue, options.visible, 'ui panel visible')
  optional(booleanValue, options.grabbable, 'ui panel grabbable')
  local grabTarget = options.grabTarget
  if grabTarget ~= nil then
    assert(type(grabTarget) == 'table', 'ui panel grabTarget: expected a surface')
    assert(type(grabTarget.dead) == 'boolean', 'ui panel grabTarget: expected a surface dead flag')
    assert(type(grabTarget.raycast) == 'function', 'ui panel grabTarget: expected a surface raycast')
    assert(type(grabTarget.setPose) == 'function', 'ui panel grabTarget: expected a movable surface')
  end
  callback(options.draw, 'ui panel draw')
  local overrides = theme.copyOverrides(options.theme)
  local pose = if options.pose ~= nil then lovr.math.newMat4(geometry.validatePose(options.pose)) else nil
  return table.freeze {
    name = options.name,
    pose = pose,
    width = options.width,
    height = options.height,
    logicalWidth = options.logicalWidth,
    logicalHeight = options.logicalHeight,
    visible = options.visible,
    grabbable = options.grabbable,
    grabTarget = grabTarget,
    titlebar = if options.titlebar then titlebarOptions.parse(options.titlebar) else nil,
    theme = overrides,
    draw = options.draw,
  }
end

function validation.button(options: ui.ButtonOptions): ui.ButtonOptions
  local copied = copyControl(options, BUTTON, 'button')
  callback(copied.onActivate, 'ui button onActivate', true)
  return copied
end

function validation.textField(options: ui.TextFieldOptions): ui.TextFieldOptions
  local copied = copyControl(options, TEXT, 'text field')
  optional(stringValue, copied.value, 'ui text field value')
  callback(copied.onChange, 'ui text field onChange')
  callback(copied.onSubmit, 'ui text field onSubmit')
  callback(copied.onCancel, 'ui text field onCancel')
  return copied
end

function validation.choice(options: ui.ChoiceOptions): ui.ChoiceOptions
  local copied = copyControl(options, CHOICE, 'choice')
  callback(copied.onChange, 'ui choice onChange', true)
  local items = validation.items(copied.items)
  validation.selected(items, copied.selected)
  local result = table.clone((copied :: unknown) :: { [string]: unknown })
  result.items = items
  return (table.freeze(result) :: unknown) :: ui.ChoiceOptions
end

function validation.list(options: ui.ListOptions): ui.ListOptions
  local copied = copyControl(options, CHOICE, 'list')
  callback(copied.onChange, 'ui list onChange')
  local items = validation.items(copied.items)
  validation.selected(items, copied.selected)
  local result = table.clone((copied :: unknown) :: { [string]: unknown })
  result.items = items
  return (table.freeze(result) :: unknown) :: ui.ListOptions
end

function validation.region(options: ui.RegionOptions): ui.RegionOptions
  local copied = copyControl(options, REGION, 'region')
  callback(copied.onPointer, 'ui region onPointer')
  optional(booleanValue, copied.wantsKeyboard, 'ui region wantsKeyboard')
  local rawReceiver = copied.receiver
  if rawReceiver ~= nil then
    local raw: unknown = rawReceiver
    assert(type(raw) == 'table' and getmetatable(raw) == nil, 'ui region receiver: a plain table is required')
    plugin.rejectUnknownFields('ui region receiver', rawReceiver, RECEIVER, 3)
    callback(rawReceiver.key, 'ui region receiver key', true)
    callback(rawReceiver.text, 'ui region receiver text', true)
    callback(rawReceiver.onFocus, 'ui region receiver onFocus')
    callback(rawReceiver.onBlur, 'ui region receiver onBlur')
  end
  local result = table.clone((copied :: unknown) :: { [string]: unknown })
  result.items = if copied.items ~= nil then validation.regionItems(copied.items) else nil
  result.receiver = if rawReceiver ~= nil then table.freeze(table.clone(rawReceiver)) else nil
  return (table.freeze(result) :: unknown) :: ui.RegionOptions
end

function validation.regionItems(items: { read [number]: ui.RegionItem }): { read [number]: ui.RegionItem }
  local copied = regionItems.parse(items, 'ui region items')
  local ids: { [string]: boolean } = {}
  for _, item in copied do
    assert(not ids[item.id], 'ui region items: ids are unique')
    ids[item.id] = true
    geometry.validateBounds(item.bounds)
    if item.route ~= nil then
      geometry.validatePolyline(item.route)
    end
  end
  return copied
end

function validation.items(items: { read [number]: ui.Item }): { read [number]: ui.Item }
  local copied = collectionItems.parse(items, 'ui collection items')
  local ids: { [string]: boolean } = {}
  for _, item in copied do
    assert(not ids[item.id], 'ui collection items: ids are unique')
    ids[item.id] = true
  end
  return copied
end

function validation.selected(items: { read [number]: ui.Item }, selected: string?): ()
  if selected == nil then
    return
  end
  identifier.parse(selected, 'ui collection selected')
  for _, item in items do
    if item.id == selected then
      return
    end
  end
  error 'ui collection selected: id must name an item'
end

copyControl = function<T>(options: T, allowed: { string }, kind: string): T
  assert(type(options) == 'table' and getmetatable(options) == nil, 'ui ' .. kind .. ': options are a plain table')
  local raw = (options :: unknown) :: { [string]: unknown }
  plugin.rejectUnknownFields('ui ' .. kind, raw, allowed, 3)
  identifier.parse(raw.id, 'ui ' .. kind .. ' id')
  optional(stringValue, raw.label, 'ui ' .. kind .. ' label')
  optional(booleanValue, raw.enabled, 'ui ' .. kind .. ' enabled')
  optional(numberValue, raw.z, 'ui ' .. kind .. ' z')
  callback(raw.draw, 'ui ' .. kind .. ' draw')
  local copied = table.clone(raw)
  copied.bounds = geometry.validateBounds((raw.bounds :: unknown) :: ui.Bounds)
  copied.theme = theme.copyOverrides((raw.theme :: unknown) :: ui.ThemeOverrides?)
  return (table.freeze(copied) :: unknown) :: T
end

callback = function(value: unknown, label: string, required: boolean?): ()
  assert((value == nil and not required) or type(value) == 'function', label .. ': a function is required')
end

optional = function<T>(descriptor: schema.Schema<T, T>, value: unknown, label: string): ()
  if value ~= nil then
    descriptor.parse(value, label)
  end
end

return table.freeze(validation)
