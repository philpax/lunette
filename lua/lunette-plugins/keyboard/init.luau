-- Provides owner-scoped keyboards built from the provider's rows, layers, and style. See lua/lunette-plugins/keyboard/README.md.
local config = require '@lunette-plugins/keyboard/config'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local theme = require '@lunette-contracts/theme'
local hooks = require '@self/hooks'
local build = require '@lunette-plugins/keyboard/service'

export type Settings = config.Settings
export type Key = keyboard.Key
export type KeyRow = keyboard.KeyRow
export type Board = hooks.Board
export type RenderedKey = hooks.RenderedKey
export type Style = hooks.Style
export type KeyState = hooks.KeyState
export type OnKey = hooks.OnKey
export type DrawKey = hooks.DrawKey
export type Pointer = hooks.Pointer
export type Press = hooks.Press
export type Paint = hooks.Paint

export type Config = config.Config

return plugin.provider {
  name = 'keyboard',
  capability = keyboard.capability,
  requires = { focus.capability, theme.capability },
  schema = config.schema,
  build = build,
}
