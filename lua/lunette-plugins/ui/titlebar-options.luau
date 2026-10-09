-- Validates detached titlebar options and action identities.
local plugin = require '@lunette-plugin'
local ui = require '@lunette-contracts/ui'
local styleDefinition = require './titlebar-style'

local titlebarOptions = {}

function titlebarOptions.parse(given: ui.TitlebarOptions): ui.TitlebarOptions
  assert(type(given) == 'table' and getmetatable(given) == nil, 'ui titlebar: options are a plain table')
  plugin.rejectUnknownFields(
    'ui titlebar',
    given,
    { 'title', 'onClose', 'closeId', 'actions', 'style', 'draggable' },
    3
  )
  assert(type(given.title) == 'string', 'ui titlebar: title is a string')
  assert(given.onClose == nil or type(given.onClose) == 'function', 'ui titlebar: onClose is a function')
  assert(
    given.closeId == nil or (type(given.closeId) == 'string' and given.closeId ~= ''),
    'ui titlebar: closeId is non-empty'
  )
  assert(given.draggable == nil or type(given.draggable) == 'boolean', 'ui titlebar: draggable is a boolean')
  local actions: { ui.TitlebarAction } = {}
  local ids: { [string]: boolean } = {}
  if given.onClose then
    ids[given.closeId or 'close'] = true
  end
  if given.actions ~= nil then
    assert(type(given.actions) == 'table' and getmetatable(given.actions) == nil, 'ui titlebar: actions are an array')
    local count = 0
    for key in given.actions do
      assert(
        type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= #given.actions,
        'ui titlebar: actions are dense'
      )
      count += 1
    end
    assert(count == #given.actions, 'ui titlebar: actions are dense')
    for _, action in given.actions do
      assert(type(action) == 'table' and getmetatable(action) == nil, 'ui titlebar: action is a plain table')
      plugin.rejectUnknownFields('ui titlebar action', action, { 'id', 'label', 'width', 'enabled', 'run' }, 3)
      assert(
        type(action.id) == 'string' and action.id ~= '' and not ids[action.id],
        'ui titlebar: action ids are unique'
      )
      assert(type(action.label) == 'string', 'ui titlebar: action label is a string')
      assert(type(action.run) == 'function', 'ui titlebar: action run is a function')
      assert(action.enabled == nil or type(action.enabled) == 'boolean', 'ui titlebar: action enabled is a boolean')
      assert(
        action.width == nil or (action.width > 0 and action.width < math.huge),
        'ui titlebar: action width is positive'
      )
      ids[action.id] = true
      actions[#actions + 1] = table.freeze(table.clone(action))
    end
  end
  return table.freeze {
    title = given.title,
    onClose = given.onClose,
    closeId = given.closeId,
    actions = table.freeze(actions),
    style = if given.style then styleDefinition.schema.parse(given.style, 'ui titlebar style') else nil,
    draggable = given.draggable,
  }
end

return titlebarOptions
