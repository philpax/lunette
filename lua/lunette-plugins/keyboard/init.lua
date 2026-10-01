-- The keyboard provider; resources are acquired during activation.
--
-- `style` sets the default key size, spacing, depths, and colours that a
-- keyboard's own options override. `rows` sets the default key rows, which are
-- a compact ANSI arrangement unless configured; a keyboard's own `rows`
-- option overrides them.
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local build = require '@lunette-plugins/keyboard/service'
local rows = require '@lunette-plugins/keyboard/rows'

export type Settings = build.Settings
export type Service = keyboard.Service

-- What a configuration gives: every option optional.
export type Config = {
  read rows: { keyboard.KeyRow }?,
  read style: {
    read keyUnit: number?,
    read gap: number?,
    read plateDepth: number?,
    read legendDepth: number?,
    read margin: number?,
    read plateColor: { number }?,
    read keyColor: { number }?,
    read heldColor: { number }?,
    read hoverColor: { number }?,
    read legendColor: { number }?,
    read legendHeight: number?,
  }?,
}

return plugin.provider<<Config, Settings, Service>> {
  name = 'keyboard',
  capability = keyboard.capability,
  requires = { interaction = interaction.capability },
  defaults = {
    rows = rows,
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
  },
  build = build,
}
