-- The manager as its components see it: the controller state, the revision store that re-renders them after a
-- change, and the operations the shell provides.

local ui = require '@lunette-plugins/ui/react'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local controller = require '../composition/controller'
local graphKinds = require './graph-kinds'

local model = {}

export type Model = {
  read state: controller.State,
  read revision: ui.WritableStore<number>,
  -- Runs a change to the controller state and re-renders.
  read change: (() -> ()) -> (),
  -- Runs an action by id, asking for confirmation first when the action unloads plugins.
  read invoke: (string) -> (),
  read close: () -> (),
  read kinds: graphKinds.Constructors,
  read sidebarWidth: number,
  -- The graph canvas, which the shell measures after layout.
  read canvas: uiHost.Ref,
  -- Focuses a text field, which takes the session's keyboard focus for the panel.
  read focusField: (uiHost.Node) -> (),
  -- Returns the keyboard focus a text field took when its edit ends.
  read releaseField: () -> (),
}

local Context = ui.createContext(nil :: Model?)

function model.provide(value: Model, children: ui.Child): ui.Child
  return ui.provide(Context, value, children)
end

-- The model, re-rendering the calling component whenever the controller state changes.
function model.use(): Model
  local value = assert(ui.useContext(Context), 'plugin manager: a component rendered outside the manager')
  ui.useStore(value.revision)
  return value
end

export type ButtonOptions = { read variant: string?, read grow: number? }

-- A button for a controller action, disabled with the action's reason.
function model.button(c: uiComponents.Service, value: Model, id: string, options: ButtonOptions?): ui.Child
  local button = controller.button(value.state, id)
  if not button then
    return nil
  end
  return c.Button {
    key = id,
    label = button.label,
    variant = options and options.variant,
    grow = options and options.grow,
    disabledReason = button.reason,
    onActivate = function(): ()
      value.invoke(id)
    end,
  }
end

-- Segmented options for controller actions, each disabled with its action's reason.
function model.options(value: Model, ids: { string }): { uiComponents.Option }
  local result: { uiComponents.Option } = {}
  for _, id in ids do
    local button = controller.button(value.state, id)
    if button then
      result[#result + 1] = { id = id, label = button.label, disabledReason = button.reason }
    end
  end
  return result
end

return model
