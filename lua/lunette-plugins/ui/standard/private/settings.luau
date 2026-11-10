-- The Settings control a titled panel shows in its header: quick lock icons, a gear, and a popup with the panel's
-- bend, axis, and both locks. The control reads and writes one Controller, so a native titlebar's Settings target the
-- native panel and a toolkit panel's Settings target the panel that holds the header.

local uiHost = require '@lunette-contracts/ui-host'
local schema = require '@lunette-plugin/schema'
local curvature = require './curvature'
local icons = require './icons'

local element = uiHost.element

local settings = {}

-- One lock the control offers, and whether it applies to this panel. `reason` is shown when it does not.
export type Lock = {
  read available: boolean,
  read reason: string?,
  read get: () -> boolean,
  read set: (boolean) -> (),
}

export type Controller = {
  read bend: () -> uiHost.Bend,
  read setCurve: (number, number?, boolean?) -> (),
  -- Whether the axis is offered, whether a bend away from the viewer is offered, and why the axis is not.
  read axis: boolean,
  read negative: boolean,
  read axisReason: string?,
  read inputLock: Lock,
  read transformLock: Lock,
}

local function checked(value: unknown): Controller
  local controller = value :: any
  if type(controller) ~= 'table' then
    error('ui standard: a properties controller is a table, not a ' .. type(controller))
  end
  if type(controller.bend) ~= 'function' or type(controller.setCurve) ~= 'function' then
    error 'ui standard: a properties controller has bend and setCurve functions'
  end
  for _, name in { 'axis', 'negative' } do
    if type(controller[name]) ~= 'boolean' then
      error('ui standard: a properties controller has a boolean ' .. name)
    end
  end
  for _, name in { 'inputLock', 'transformLock' } do
    local lock = controller[name]
    if
      type(lock) ~= 'table'
      or type(lock.available) ~= 'boolean'
      or type(lock.get) ~= 'function'
      or type(lock.set) ~= 'function'
    then
      error('ui standard: a properties controller has a ' .. name .. ' with available, get, and set')
    end
  end
  return value :: Controller
end

settings.schema = schema.custom<<Controller>> { runtimeType = 'table', validate = checked }

-- The default controller writes the panel the header is in, as a toolkit panel's Settings do.
local function ownPanel(act: uiHost.Actions): Controller
  return {
    bend = act.bend,
    setCurve = act.setCurve,
    axis = true,
    negative = true,
    axisReason = nil,
    inputLock = {
      available = true,
      reason = nil,
      get = act.locked,
      set = function(value: boolean): ()
        act.setLocked(value)
      end,
    },
    transformLock = {
      available = act.transformAvailable(),
      reason = if act.transformAvailable() then nil else 'This panel has no placement a grab can move.',
      get = act.transformLocked,
      set = function(value: boolean): ()
        act.setTransformLocked(value)
      end,
    },
  }
end

local function text(value: string, style: string, key: string, color: string?): uiHost.Element
  return element('lunette/text', { key = key, text = value, style = style, color = color })
end

-- Rounds a value to the control's step so a slider release does not drift on float error.
local function settled(value: number): number
  return math.floor(value + 0.5)
end

-- Draws the header's lock icons and gear and, while open, the Settings popup.
function settings.control(
  props: uiHost.Props,
  state: { read [string]: any },
  act: uiHost.Actions,
  given: Controller?
): uiHost.Child
  if props.propertiesControl == false then
    return nil
  end
  local controller = given or ownPanel(act)
  local inputAvailable = controller.inputLock.available
  local transformAvailable = controller.transformLock.available

  -- A change made outside the control, such as the titlebar's own action, reaches the state on the next expand.
  local externalInput = controller.inputLock.get()
  local externalTransform = controller.transformLock.get()
  if
    not state.settingsOpen
    and (not state.seeded or state.inputLocked ~= externalInput or state.transformLocked ~= externalTransform)
  then
    act.setState { seeded = true, inputLocked = externalInput, transformLocked = externalTransform }
  end
  local inputLocked = if state.settingsOpen then state.inputLocked == true else externalInput
  local transformLocked = if state.settingsOpen then state.transformLocked == true else externalTransform

  local bend = controller.bend()
  local shown = curvature.read(bend)
  local bendLimit = curvature.MAX_BEND
  local minimum = if controller.negative then -bendLimit else 0
  local bendValue = math.clamp(shown.bend, minimum, bendLimit)
  local axisValue = shown.axis
  local axisRadians = math.rad(axisValue)
  local bendText = if type(state.bendText) == 'string' then state.bendText else curvature.format(bendValue)
  local axisText = if type(state.axisText) == 'string' then state.axisText else curvature.format(axisValue)

  local function curveFor(degrees: number, axis: number): number
    return curvature.curve(degrees, axis, bend.width, bend.height)
  end

  local function preview(degrees: number, axis: number): ()
    controller.setCurve(curveFor(degrees, axis), axis, false)
  end

  local function commit(degrees: number, axis: number): ()
    controller.setCurve(curveFor(degrees, axis), axis, true)
    act.setState {
      bendText = curvature.format(degrees),
      axisText = curvature.format(curvature.wrapAxis(math.deg(axis))),
      bendInvalid = false,
      axisInvalid = false,
      committedCurve = curveFor(degrees, axis),
      committedAxis = axis,
    }
  end

  local function open(): ()
    local current = controller.bend()
    local values = curvature.read(current)
    act.setState {
      settingsOpen = true,
      seeded = true,
      inputLocked = controller.inputLock.get(),
      transformLocked = controller.transformLock.get(),
      bendText = curvature.format(math.clamp(values.bend, minimum, bendLimit)),
      axisText = curvature.format(values.axis),
      bendInvalid = false,
      axisInvalid = false,
      committedCurve = current.curve,
      committedAxis = current.axis,
    }
  end

  local function close(): ()
    act.setState { settingsOpen = false }
    local curve = if type(state.committedCurve) == 'number' then state.committedCurve else bend.curve
    local axis = if type(state.committedAxis) == 'number' then state.committedAxis else bend.axis
    controller.setCurve(curve, axis, false)
  end

  local function toggle(): ()
    if state.settingsOpen then
      close()
    else
      open()
    end
  end

  local function setInputLocked(value: boolean): ()
    act.setState { inputLocked = value }
    controller.inputLock.set(value)
  end

  local function setTransformLocked(value: boolean): ()
    act.setState { transformLocked = value }
    controller.transformLock.set(value)
  end

  -- A quick lock is an unlock affordance: it appears only while its lock is active, and the Settings toggles are the
  -- way to enable one. A hidden icon never offers to turn something on.
  local function lockButton(
    key: string,
    icon: uiHost.ImageSource,
    value: boolean,
    label: string,
    run: () -> ()
  ): uiHost.Element?
    local available = if key == 'input-lock' then inputAvailable else transformAvailable
    if not available or not value then
      return nil
    end
    return element('lunette/button', {
      key = key,
      label = label,
      icon = icon,
      active = true,
      variant = 'band',
      onActivate = run,
    })
  end

  local function column(
    key: string,
    label: string,
    value: number,
    valueText: string,
    invalid: boolean,
    disabled: boolean,
    reason: string?,
    low: number,
    high: number,
    applyPreview: (number) -> (),
    applyCommit: (number) -> (),
    onText: (string) -> (),
    onTextCommit: (string) -> ()
  ): uiHost.Element
    return element('lunette/column', {
      key = key,
      gap = 'xs',
      element('lunette/row', {
        key = 'heading',
        align = 'center',
        gap = 'sm',
        element('lunette/text', { key = 'label', text = label, style = 'body', grow = 1 }),
        element('lunette/text-field', {
          key = 'value',
          value = valueText,
          mono = true,
          grow = 0,
          invalid = invalid,
          disabled = disabled,
          disabledReason = reason,
          onChange = onText,
          onSubmit = onTextCommit,
          onCancel = function()
            act.setState { bendText = curvature.format(bendValue), axisText = curvature.format(axisValue) }
          end,
        }),
      }),
      -- The slider draws no heading of its own: the row above holds the label and the numeric entry.
      element('lunette/slider', {
        label = label,
        value = value,
        min = low,
        max = high,
        step = 1,
        showHeading = false,
        disabled = disabled,
        disabledReason = reason,
        onChange = applyPreview,
        onCommit = applyCommit,
      }),
    })
  end

  local function bendEntry(text: string): ()
    act.setState { bendText = text, bendInvalid = false }
  end

  local function bendSubmit(text: string): ()
    local value = tonumber(text)
    if not value or value ~= value or value == math.huge or value == -math.huge then
      act.setState { bendInvalid = true }
      return
    end
    commit(math.clamp(settled(value), minimum, bendLimit), axisRadians)
    act.setState { bendText = curvature.format(math.clamp(settled(value), minimum, bendLimit)) }
  end

  local function axisEntry(text: string): ()
    act.setState { axisText = text, axisInvalid = false }
  end

  local function axisSubmit(text: string): ()
    local value = curvature.parse(text, -curvature.MAX_AXIS, curvature.MAX_AXIS)
    if not value then
      act.setState { axisInvalid = true }
      return
    end
    local axis = math.rad(curvature.wrapAxis(value))
    commit(bendValue, axis)
  end

  local popup = if state.settingsOpen
    then element('lunette/portal', {
      key = 'popup',
      placement = 'above',
      handoff = true,
      -- The popup stays where it opened: changing the bend must not move the control being used.
      sticky = true,
      onDismiss = close,
      element('lunette/menu', {
        element('lunette/body', {
          key = 'body',
          gap = 'md',
          text('Settings', 'heading', 'title'),
          column(
            'bend',
            'Bend',
            bendValue,
            bendText,
            state.bendInvalid == true,
            false,
            nil,
            minimum,
            bendLimit,
            function(value: number)
              act.setState { bendText = curvature.format(value), bendInvalid = false }
              preview(settled(value), axisRadians)
            end,
            function(value: number)
              commit(settled(value), axisRadians)
            end,
            bendEntry,
            bendSubmit
          ),
          column(
            'axis',
            'Axis',
            axisValue,
            axisText,
            state.axisInvalid == true,
            not controller.axis,
            controller.axisReason,
            -curvature.MAX_AXIS,
            curvature.MAX_AXIS,
            function(value: number)
              act.setState { axisText = curvature.format(value), axisInvalid = false }
              preview(bendValue, math.rad(value))
            end,
            function(value: number)
              commit(bendValue, math.rad(curvature.wrapAxis(value)))
            end,
            axisEntry,
            axisSubmit
          ),
          -- A disabled axis states its reason in place, not only in the hover tooltip.
          if not controller.axis
            then text(controller.axisReason or 'The axis is unavailable.', 'caption', 'axis-reason', 'muted')
            else nil,
          element('lunette/separator', {}),
          element('lunette/toggle', {
            key = 'input-lock',
            label = 'Input lock',
            value = inputLocked,
            disabled = not inputAvailable,
            disabledReason = controller.inputLock.reason,
            onChange = setInputLocked,
          }),
          element('lunette/toggle', {
            key = 'transform-lock',
            label = 'Transform lock',
            value = transformLocked,
            disabled = not transformAvailable,
            disabledReason = controller.transformLock.reason,
            onChange = setTransformLocked,
          }),
        }),
      }),
    })
    else nil

  return element('lunette/row', {
    key = 'settings',
    align = 'center',
    gap = 'xs',
    lockButton('input-lock', icons.inputLock, inputLocked, 'Unlock input', function()
      setInputLocked(not inputLocked)
    end),
    lockButton('transform-lock', icons.transformLock, transformLocked, 'Unlock transform', function()
      setTransformLocked(not transformLocked)
    end),
    element('lunette/button', {
      key = 'gear',
      label = 'Settings',
      icon = icons.gear,
      active = state.settingsOpen == true,
      variant = 'band',
      onActivate = toggle,
    }),
    popup,
  })
end

return settings
