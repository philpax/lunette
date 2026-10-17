-- The backdrop control panel's content, rendered from the backdrop's stores.
local vocabulary = require '@lunette-contracts/vocabulary'
local ui = require '@lunette-plugins/ui/react'
local selection = require '../selection/selection'
local stores = require './stores'
local kinds = require '../visualisation/kinds'
local scene = require '../visualisation/scene'

local component = {}

-- Requests the panel makes. Each one changes the backdrop's choices; the stores then show the result.
export type Actions = {
  read setEnabled: (boolean) -> (),
  read setReactive: (boolean) -> (),
  read setMode: (selection.Mode) -> (),
  read pinAttended: () -> (),
  -- Pins the process behind a row token. Rows hold tokens rather than handles, so a removed row that the host still
  -- references keeps no process alive.
  read pin: (string) -> (),
  read setResponse: (number) -> (),
  read setMotion: (number) -> (),
  read setDiagnostic: (selection.Diagnostic) -> (),
  read close: () -> (),
}

export type Props = {
  read settings: vocabulary.Store<stores.Settings>,
  read applications: vocabulary.Store<{ stores.Application }>,
  read summary: vocabulary.Store<scene.Summary>,
  read views: kinds.Constructors,
  read actions: Actions,
}

local INTENSITY = table.freeze {
  { value = 0, label = 'None' },
  { value = 0.25, label = 'Low' },
  { value = 0.5, label = 'Medium' },
  { value = 0.75, label = 'High' },
  { value = 1, label = 'Full' },
}

local SOURCES = table.freeze {
  { id = 'system', label = 'System mix' },
  { id = 'application', label = 'Pinned' },
  { id = 'attention', label = 'Attention' },
}

local DIAGNOSTICS = table.freeze {
  { id = 'none', label = 'Off' },
  { id = 'direction', label = 'Sky direction' },
  { id = 'coordinates', label = 'Field coordinates' },
  { id = 'cells', label = 'Noise cells' },
  { id = 'density', label = 'Field density' },
  { id = 'field', label = 'Field, boosted' },
}

-- The panel width in metres. The panel takes its height from the content.
component.WIDTH = 0.44

-- The applications list scrolls within this height in metres.
local LIST_HEIGHT = 0.15

-- The sky model's size, which is also the height of the skyline beside it, in metres.
local VIEW_SIZE = 0.13

local isMode: (string) -> boolean
local isDiagnostic: (string) -> boolean

component.BackdropControls = ui.component('BackdropControls', function(props: Props): ui.Child
  local c = ui.useComponents()
  local settings = ui.useStore(props.settings)
  local applications = ui.useStore(props.applications)
  local summary = ui.useStore(props.summary)
  local actions = props.actions
  local views = props.views
  return c.Panel {
    width = component.WIDTH,
    title = 'Backdrop',
    onClose = actions.close,
    c.Body {
      key = 'body',
      c.Toggle {
        key = 'enabled',
        label = 'Backdrop',
        value = settings.enabled,
        onChange = actions.setEnabled,
      },
      c.Toggle {
        key = 'reactive',
        label = 'Audio reactivity',
        value = settings.reactive,
        onChange = actions.setReactive,
      },
      c.Section {
        key = 'source',
        title = 'Audio source',
        c.Segmented {
          key = 'mode',
          value = settings.mode,
          options = SOURCES,
          onChange = function(mode: string): ()
            if isMode(mode) then
              actions.setMode(mode :: selection.Mode)
            end
          end,
        },
        c.Button {
          key = 'pin',
          label = 'Pin the attended application',
          disabledReason = settings.pinReason,
          onActivate = actions.pinAttended,
        },
        c.Text { key = 'status', text = settings.status, style = 'caption' },
        if settings.notice
          then c.Text { key = 'notice', text = settings.notice, style = 'caption', color = 'muted' }
          else nil,
      },
      c.Section {
        key = 'applications',
        title = 'Applications',
        if #applications == 0
          then c.Text { key = 'empty', text = 'No applications are running.', style = 'caption', color = 'muted' }
          else nil,
        c.ScrollView {
          key = 'scroll',
          maxHeight = LIST_HEIGHT,
          c.List {
            key = 'rows',
            ui.map(applications, function(application: stores.Application): ui.Child
              local token = application.token
              return c.ListRow {
                key = application.token,
                title = application.title,
                detail = application.detail,
                trailing = application.trailing,
                selected = application.selected,
                onActivate = function(): ()
                  actions.pin(token)
                end,
              }
            end),
          },
        },
      },
      c.Section {
        key = 'intensity',
        title = 'Intensity',
        c.Slider {
          key = 'response',
          label = 'Response',
          min = 0,
          max = 1,
          value = settings.response,
          detents = INTENSITY,
          onChange = actions.setResponse,
        },
        c.Slider {
          key = 'motion',
          label = 'Motion',
          min = 0,
          max = 1,
          value = settings.motion,
          detents = INTENSITY,
          onChange = actions.setMotion,
        },
      },
      c.Section {
        key = 'diagnostics',
        title = 'Diagnostic view',
        c.Dropdown {
          key = 'view',
          value = settings.diagnostic,
          options = DIAGNOSTICS,
          onChange = function(diagnostic: string): ()
            if isDiagnostic(diagnostic) then
              actions.setDiagnostic(diagnostic :: selection.Diagnostic)
            end
          end,
        },
      },
      -- The views stay while reactivity is off, so toggling it does not resize the panel.
      c.Section {
        key = 'response',
        title = 'Response',
        c.Row {
          key = 'views',
          gap = 'sm',
          views.Model { key = 'model', size = VIEW_SIZE },
          views.Skyline { key = 'skyline', height = VIEW_SIZE },
        },
        c.Text {
          key = 'onsets',
          text = if settings.reactive then scene.caption(summary) else 'Audio reactivity is off.',
          style = 'caption',
          color = 'muted',
        },
      },
    },
  }
end)

isMode = function(value: string): boolean
  return value == 'system' or value == 'application' or value == 'attention'
end

isDiagnostic = function(value: string): boolean
  for _, option in DIAGNOSTICS do
    if option.id == value then
      return true
    end
  end
  return false
end

return component
