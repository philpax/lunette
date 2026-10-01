-- The keyboard provider. The options and the `onKey` and `drawKey` around hooks are in
-- docs/dev/lua-api.md#keyboard; a keyboard's own options override `rows`, `layers`, and `style`.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local keys = require '@lunette-contracts/keys'
local board = require '@lunette-plugins/keyboard/board'
local build = require '@lunette-plugins/keyboard/service'
local rows = require '@lunette-plugins/keyboard/rows'
local validation = require '@lunette-plugins/keyboard/validation'

export type Settings = build.Settings
export type Key = keyboard.Key
export type KeyRow = keyboard.KeyRow
export type Action = keyboard.Action
export type Style = keyboard.Style
export type Service = keyboard.Service
export type Board = board.Board
export type RenderedKey = board.RenderedKey
export type KeyState = board.KeyState
export type OnKey = board.OnKey
export type DrawKey = board.DrawKey

-- What a configuration gives: every option optional.
export type Config = {
  read rows: { keyboard.KeyRow }?,
  read layers: { [string]: { keyboard.KeyRow } }?,
  read style: keyboard.StyleOptions?,
  read modifierKeys: { [number]: string }?,
  read locks: { string }?,
  read onKey: OnKey?,
  read drawKey: DrawKey?,
}

local function onKey(target: Board, key: RenderedKey, pointer: board.Pointer, base: board.Press): ()
  base(target, key, pointer)
end

local function drawKey(pass: Pass, key: RenderedKey, state: KeyState, base: board.Paint): ()
  base(pass, key, state)
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'keyboard',
  capability = keyboard.capability,
  requires = { focus = focus.capability },
  defaults = {
    rows = rows,
    layers = {},
    style = {
      keyUnit = 0.028,
      gap = 0.004,
      plateDepth = 0.002,
      legendDepth = 0.001,
      margin = 0.008,
      plateColor = { 0.1, 0.1, 0.13, 0.92 },
      keyColor = { 0.2, 0.2, 0.24, 1 },
      heldColor = { 0.35, 0.55, 0.95, 1 },
      hoverColor = { 0.4, 0.42, 0.5, 1 },
      legendColor = { 1, 1, 1, 1 },
      legendHeight = 0.012,
    },
    modifierKeys = keys.MODIFIER_KEYS,
    locks = lunette.lockingModifierNames(),
    onKey = onKey,
    drawKey = drawKey,
  },
  validate = validation.settings,
  build = build,
}
