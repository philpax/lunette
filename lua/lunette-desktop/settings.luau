-- Desktop settings are keyed by entry id and reuse each entry's configuration descriptor.

local schema = require '@lunette-plugin/schema'
local interaction = require '@lunette-plugins/interaction/pointers/config'
local laser = require '@lunette-plugins/input/laser/config'
local keyboard = require '@lunette-plugins/input/keyboard/config'
local uiHost = require '@lunette-plugins/ui/host/config'
local theme = require '@lunette-plugins/ui/theme/config'
local notifications = require '@lunette-plugins/ui/notifications/config'
local accessibility = require '@lunette-plugins/ui/accessibility/config'
local panels = require '@lunette-plugins/panels/service/config'
local rules = require '@lunette-plugins/window/rule-resolver/config'
local placement = require '@lunette-plugins/window/placement/config'
local layoutArc = require '@lunette-plugins/layout/arc/config'
local errors = require '@lunette-plugins/diagnostics/error-stream/config'
local pacing = require '@lunette-plugins/pacing/service/config'
local scale = require '@lunette-plugins/scale/service/config'
local audio = require '@lunette-plugins/audio/capture/config'
local audioAnalysis = require '@lunette-plugins/audio/analysis/config'
local desktopBackdrop = require '@lunette-plugins/environment/backdrop/config'
local desktopHint = require '@lunette-plugins/environment/empty-desktop-hint/config'
local desktopDecorations = require '@lunette-plugins/panels/decorations/config'
local desktopMousePointer = require '@lunette-plugins/input/mouse-pointer/config'
local desktopSimulator = require '@lunette-plugins/input/simulator/config'
local desktopKeyboard = require '@lunette-plugins/input/keyboard-display/config'
local desktopMenu = require '@lunette-plugins/menu/wrist-menu/config'
local desktopErrors = require '@lunette-plugins/diagnostics/error-display/config'
local recovery = require '@lunette-plugins/diagnostics/recovery/config'
local desktopWorkspaces = require '@lunette-plugins/workspace/controller/config'
local desktopMonitors = require '@lunette-plugins/panels/monitors/config'
local desktopAccessibility = require '@lunette-plugins/ui/accessibility-settings/config'
local desktopRules = require '@lunette-plugins/window/configured-rules/config'
local desktopPersistence = require '@lunette-plugins/layout/persistence/config'
local desktopArrange = require '@lunette-plugins/layout/arrange/config'
local desktopAdoption = require '@lunette-plugins/window/adoption-controller/config'
local desktopPacing = require '@lunette-plugins/pacing/controller/config'
local desktopManager = require '@lunette-plugins/session/plugin-manager/config'

-- Typed constructor witnesses avoid expanding nested key unions and recursive rule contracts at each wrapper.
local optional = (schema.optional :: unknown) :: <I, O>(schema.Schema<I, O>) -> schema.Schema<I?, O?>
local shape: {
  read interaction: schema.Schema<interaction.Config?, interaction.Settings?>,
  read laser: schema.Schema<laser.Config?, laser.Settings?>,
  read keyboard: schema.Schema<keyboard.Config?, keyboard.Settings?>,
  read ['ui-host']: schema.Schema<uiHost.Config?, uiHost.Settings?>,
  read theme: schema.Schema<theme.Config?, theme.Settings?>,
  read notifications: schema.Schema<notifications.Config?, notifications.Settings?>,
  read accessibility: schema.Schema<accessibility.Config?, accessibility.Settings?>,
  read panels: schema.Schema<panels.Config?, panels.Settings?>,
  read rules: schema.Schema<rules.Config?, rules.Settings?>,
  read placement: schema.Schema<placement.Config?, placement.Settings?>,
  read ['layout/arc']: schema.Schema<layoutArc.Config?, layoutArc.Settings?>,
  read errors: schema.Schema<errors.Config?, errors.Settings?>,
  read pacing: schema.Schema<pacing.Config?, pacing.Settings?>,
  read scale: schema.Schema<scale.Config?, scale.Settings?>,
  read audio: schema.Schema<audio.Config?, audio.Settings?>,
  read ['audio-analysis']: schema.Schema<audioAnalysis.Config?, audioAnalysis.Settings?>,
  read ['desktop/backdrop']: schema.Schema<desktopBackdrop.Config?, desktopBackdrop.Settings?>,
  read ['desktop/hint']: schema.Schema<desktopHint.Config?, desktopHint.Settings?>,
  read ['desktop/decorations']: schema.Schema<desktopDecorations.Config?, desktopDecorations.Settings?>,
  read ['desktop/mouse-pointer']: schema.Schema<desktopMousePointer.Config?, desktopMousePointer.Settings?>,
  read ['desktop/simulator']: schema.Schema<desktopSimulator.Config?, desktopSimulator.Settings?>,
  read ['desktop/keyboard']: schema.Schema<desktopKeyboard.Config?, desktopKeyboard.Settings?>,
  read ['desktop/menu']: schema.Schema<desktopMenu.Config?, desktopMenu.Settings?>,
  read ['desktop/errors']: schema.Schema<desktopErrors.Config?, desktopErrors.Settings?>,
  read ['diagnostics/recovery']: schema.Schema<recovery.Config?, recovery.Settings?>,
  read ['desktop/workspaces']: schema.Schema<desktopWorkspaces.Config?, desktopWorkspaces.Settings?>,
  read ['desktop/monitors']: schema.Schema<desktopMonitors.Config?, desktopMonitors.Settings?>,
  read ['desktop/rules']: schema.Schema<desktopRules.Config?, desktopRules.Settings?>,
  read ['desktop/persistence']: schema.Schema<desktopPersistence.Config?, desktopPersistence.Settings?>,
  read ['desktop/arrange']: schema.Schema<desktopArrange.Config?, desktopArrange.Settings?>,
  read ['desktop/adoption']: schema.Schema<desktopAdoption.Config?, desktopAdoption.Settings?>,
  read ['desktop/pacing']: schema.Schema<desktopPacing.Config?, desktopPacing.Settings?>,
  read ['desktop/manager']: schema.Schema<desktopManager.Config?, desktopManager.Settings?>,
  read ['desktop/accessibility']: schema.Schema<desktopAccessibility.Config?, desktopAccessibility.Settings?>,
} =
  {
    interaction = optional<<interaction.Config, interaction.Settings>>(interaction.schema),
    laser = optional<<laser.Config, laser.Settings>>(laser.schema),
    keyboard = optional<<keyboard.Config, keyboard.Settings>>(keyboard.schema),
    ['ui-host'] = optional<<uiHost.Config, uiHost.Settings>>(uiHost.schema),
    theme = optional<<theme.Config, theme.Settings>>(theme.schema),
    notifications = optional<<notifications.Config, notifications.Settings>>(notifications.schema),
    accessibility = optional<<accessibility.Config, accessibility.Settings>>(accessibility.schema),
    panels = optional<<panels.Config, panels.Settings>>(panels.schema),
    rules = optional<<rules.Config, rules.Settings>>(rules.schema),
    placement = optional<<placement.Config, placement.Settings>>(placement.schema),
    ['layout/arc'] = optional<<layoutArc.Config, layoutArc.Settings>>(layoutArc.schema),
    errors = optional<<errors.Config, errors.Settings>>(errors.schema),
    pacing = optional<<pacing.Config, pacing.Settings>>(pacing.schema),
    scale = optional<<scale.Config, scale.Settings>>(scale.schema),
    audio = optional<<audio.Config, audio.Settings>>(audio.schema),
    ['audio-analysis'] = optional<<audioAnalysis.Config, audioAnalysis.Settings>>(audioAnalysis.schema),
    ['desktop/backdrop'] = optional<<desktopBackdrop.Config, desktopBackdrop.Settings>>(desktopBackdrop.schema),
    ['desktop/hint'] = optional<<desktopHint.Config, desktopHint.Settings>>(desktopHint.schema),
    ['desktop/decorations'] = optional<<desktopDecorations.Config, desktopDecorations.Settings>>(
      desktopDecorations.schema
    ),
    ['desktop/mouse-pointer'] = optional<<desktopMousePointer.Config, desktopMousePointer.Settings>>(
      desktopMousePointer.schema
    ),
    ['desktop/simulator'] = optional<<desktopSimulator.Config, desktopSimulator.Settings>>(desktopSimulator.schema),
    ['desktop/keyboard'] = optional<<desktopKeyboard.Config, desktopKeyboard.Settings>>(desktopKeyboard.schema),
    ['desktop/menu'] = optional<<desktopMenu.Config, desktopMenu.Settings>>(desktopMenu.schema),
    ['desktop/errors'] = optional<<desktopErrors.Config, desktopErrors.Settings>>(desktopErrors.schema),
    ['diagnostics/recovery'] = optional<<recovery.Config, recovery.Settings>>(recovery.schema),
    ['desktop/workspaces'] = optional<<desktopWorkspaces.Config, desktopWorkspaces.Settings>>(desktopWorkspaces.schema),
    ['desktop/monitors'] = optional<<desktopMonitors.Config, desktopMonitors.Settings>>(desktopMonitors.schema),
    ['desktop/rules'] = optional<<desktopRules.Config, desktopRules.Settings>>(desktopRules.schema),
    ['desktop/persistence'] = optional<<desktopPersistence.Config, desktopPersistence.Settings>>(
      desktopPersistence.schema
    ),
    ['desktop/arrange'] = optional<<desktopArrange.Config, desktopArrange.Settings>>(desktopArrange.schema),
    ['desktop/adoption'] = optional<<desktopAdoption.Config, desktopAdoption.Settings>>(desktopAdoption.schema),
    ['desktop/pacing'] = optional<<desktopPacing.Config, desktopPacing.Settings>>(desktopPacing.schema),
    ['desktop/manager'] = optional<<desktopManager.Config, desktopManager.Settings>>(desktopManager.schema),
    ['desktop/accessibility'] = optional<<desktopAccessibility.Config, desktopAccessibility.Settings>>(
      desktopAccessibility.schema
    ),
  }
local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = (descriptor :: unknown) :: schema.Schema<Config, Settings> }
