-- Desktop shorthand settings reuse each plugin's configuration descriptor.

local schema = require '@lunette-plugin/schema'
local menu = require '@lunette-plugins/desktop/menu/config'
local decorations = require '@lunette-plugins/desktop/decorations/config'
local arrange = require '@lunette-plugins/desktop/arrange/config'
local persistence = require '@lunette-plugins/arrangement/config'
local keyboard = require '@lunette-plugins/desktop/keyboard/config'
local rules = require '@lunette-plugins/desktop/rules/config'
local monitors = require '@lunette-plugins/desktop/monitors/config'
local hint = require '@lunette-plugins/desktop/hint/config'
local errors = require '@lunette-plugins/desktop/errors/config'
local pointing = require '@lunette-plugins/desktop/pointing/config'
local pacing = require '@lunette-plugins/desktop/pacing/config'
local workspace = require '@lunette-plugins/desktop/workspace/config'
local adoption = require '@lunette-plugins/desktop/adoption/config'
local manager = require '@lunette-plugins/desktop/manager/config'

-- Typed constructor witnesses avoid expanding nested key unions and recursive rule contracts at each wrapper.
local optional = (schema.optional :: unknown) :: <I, O>(schema.Schema<I, O>) -> schema.Schema<I?, O?>
local shape: {
  read menu: schema.Schema<menu.Config?, menu.Settings?>,
  read decorations: schema.Schema<decorations.Config?, decorations.Settings?>,
  read arrange: schema.Schema<arrange.Config?, arrange.Settings?>,
  read persistence: schema.Schema<persistence.Config?, persistence.Settings?>,
  read wristKeyboard: schema.Schema<keyboard.Config?, keyboard.Settings?>,
  read rules: schema.Schema<rules.Config?, rules.Settings?>,
  read monitors: schema.Schema<monitors.Config?, monitors.Settings?>,
  read hint: schema.Schema<hint.Config?, hint.Settings?>,
  read errors: schema.Schema<errors.Config?, errors.Settings?>,
  read pointing: schema.Schema<pointing.Config?, pointing.Settings?>,
  read pacing: schema.Schema<pacing.Config?, pacing.Settings?>,
  read workspace: schema.Schema<workspace.Config?, workspace.Settings?>,
  read adoption: schema.Schema<adoption.Config?, adoption.Settings?>,
  read manager: schema.Schema<manager.Config?, manager.Settings?>,
} =
  {
    menu = optional<<menu.Config, menu.Settings>>(menu.schema),
    decorations = optional<<decorations.Config, decorations.Settings>>(decorations.schema),
    arrange = optional<<arrange.Config, arrange.Settings>>(arrange.schema),
    persistence = optional<<persistence.Config, persistence.Settings>>(persistence),
    wristKeyboard = optional<<keyboard.Config, keyboard.Settings>>(keyboard.schema),
    rules = optional<<rules.Config, rules.Settings>>(rules.schema),
    monitors = optional<<monitors.Config, monitors.Settings>>(monitors.schema),
    hint = optional<<hint.Config, hint.Settings>>(hint.schema),
    errors = optional<<errors.Config, errors.Settings>>(errors.schema),
    pointing = optional<<pointing.Config, pointing.Settings>>(pointing.schema),
    pacing = optional<<pacing.Config, pacing.Settings>>(pacing.schema),
    workspace = optional<<workspace.Config, workspace.Settings>>(workspace.schema),
    adoption = optional<<adoption.Config, adoption.Settings>>(adoption.schema),
    manager = optional<<manager.Config, manager.Settings>>(manager.schema),
  }
local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = (descriptor :: unknown) :: schema.Schema<Config, Settings> }
