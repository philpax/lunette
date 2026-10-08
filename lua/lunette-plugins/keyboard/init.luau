-- Provides owner-scoped keyboards. Per-keyboard options override provider rows, layers, and style. See docs/dev/lua-api.md#keyboard.
local config = require '@lunette-plugins/keyboard/config'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local theme = require '@lunette-contracts/theme'
local board = require '@lunette-plugins/keyboard/board'
local build = require '@lunette-plugins/keyboard/service'
local validation = require '@lunette-plugins/keyboard/validation'

export type Settings = config.Settings
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

export type Config = config.Config

return plugin.provider {
  name = 'keyboard',
  capability = keyboard.capability,
  requires = { focus = focus.capability, theme = theme.capability },
  schema = config,
  validate = validation.settings,
  build = build,
}
