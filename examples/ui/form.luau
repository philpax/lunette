-- A third-party form built with the React-like library on the UI host, using the standard kinds, one kind of its
-- own, and the desktop's shared keyboard. A wrist-menu action opens it.
local plugin = require '@lunette-plugin'
local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local menu = require '@lunette-contracts/menu'
local ui = require '@lunette-plugins/ui/react'

export type Config = {}
export type Settings = {}

type FormProps = {
  read tapPad: uiHost.Constructor,
  read close: () -> (),
}

local MODES = {
  { id = 'quiet', label = 'Quiet' },
  { id = 'studio', label = 'Studio' },
  { id = 'outdoors', label = 'Outdoors' },
}

local DESTINATIONS = {}
for index = 1, 24 do
  DESTINATIONS[index] = { id = `destination-{index}`, title = `Destination {index}` }
end

-- A pad that counts taps: an activation is a tap, and a press that ends without one, such as when the form is
-- hidden mid-press, is a cancellation.
local function registerTapPad(host: uiHost.Service, owner: plugin.Owner): uiHost.Constructor
  local constructor = host:registerKind(owner, {
    name = 'example/tap-pad',
    focus = 'pointer',
    elevation = 'raised',
    response = { lift = true, travel = true },
    interactive = function(): boolean
      return true
    end,
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'center',
          justifyContent = 'center',
          padding = theme.spacing.md,
          minHeight = theme.sizes.row * 2,
        }
      end,
    },
    visuals = { 'example/tap-pad' },
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
      if event.kind == 'activate' then
        node:emit 'onTap'
      elseif event.kind == 'cancel' then
        node:emit 'onCancel'
      elseif event.kind ~= 'press' and event.kind ~= 'release' then
        base(node, event)
      end
    end,
  })
  host:registerVisual(owner, 'example/tap-pad', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, {
      fill = if node.state.hovered then theme.colors.hover else theme.colors.raised,
      radius = theme.radii.control,
      side = theme.colors.side,
      edges = true,
    })
  end)
  return constructor
end

local Form = ui.component('ExampleForm', function(props: FormProps): ui.Child
  local c = ui.useComponents()
  local presses, setPresses = ui.useState(0)
  local name, setName = ui.useState ''
  local mode, setMode = ui.useState 'quiet'
  local destination, setDestination = ui.useState 'destination-1'
  local taps, setTaps = ui.useState(0)
  local cancelled, setCancelled = ui.useState(0)
  local field = ui.useRef(nil :: uiHost.Node?)
  local status = `Presses: {presses}; name: {name}; mode: {mode}; destination: {destination}; taps: {taps}; `
    .. `cancelled: {cancelled};`
  return c.Panel {
    c.Header {
      key = 'header',
      title = 'Example form',
      c.Button {
        key = 'close',
        label = 'Close',
        variant = 'band',
        onActivate = function()
          -- Hiding the panel does not end its field's focus, so Close ends it first, which hides the keyboard.
          local node = field.current
          if node and not node.dead then
            node:blur()
          end
          props.close()
        end,
      },
    },
    c.Body {
      key = 'body',
      c.Row {
        key = 'actions',
        gap = 'md',
        align = 'center',
        c.Button {
          key = 'press',
          label = 'Count a press',
          variant = 'primary',
          onActivate = function()
            setPresses(presses + 1)
          end,
        },
        c.Text { key = 'count', text = `{presses} pressed`, color = 'muted' },
      },
      c.TextField { key = 'name', ref = field, value = name, placeholder = 'Name', onChange = setName },
      c.Row {
        key = 'choices',
        gap = 'lg',
        c.Section {
          key = 'mode',
          title = 'Mode',
          c.RadioGroup { key = 'mode', options = MODES, value = mode, onChange = setMode },
        },
        c.Section {
          key = 'destinations',
          title = 'Destinations',
          c.ScrollView {
            height = 0.16,
            c.List { key = 'list', items = DESTINATIONS, value = destination, onChange = setDestination },
          },
        },
      },
      props.tapPad {
        key = 'pad',
        onTap = function()
          setTaps(function(count: number): number
            return count + 1
          end)
        end,
        onCancel = function()
          setCancelled(function(count: number): number
            return count + 1
          end)
        end,
        c.Text { key = 'label', text = 'Tap to count', style = 'label' },
      },
      c.Text { key = 'status', text = status, style = 'caption', color = 'muted' },
    },
  }
end)

return plugin.consumer<<Config, Settings>> {
  name = 'example/ui/form',
  requires = { uiHost.capability, uiComponents.capability, menu.capability },
  init = function(context: plugin.Context, _settings: Settings)
    local host = context:require(uiHost.capability)
    local components = context:require(uiComponents.capability)
    local actions: menu.Service = context:require(menu.capability)
    local panel = host:newPanel(context, {
      name = 'example/ui/form',
      pose = lovr.math.newMat4():translate(vector.pack(0, 1.4, -1.4)),
      width = 0.6,
      height = 0.62,
    })
    panel:setVisible(false)
    local function setVisible(visible: boolean): ()
      if context:active() and not panel.dead then
        panel:setVisible(visible)
      end
    end
    ui.mount(
      panel,
      Form {
        tapPad = registerTapPad(host, context),
        close = function()
          setVisible(false)
        end,
      },
      { components = components, owner = context }
    )
    actions:register(context, {
      id = 'example/ui/open',
      label = 'Open example form',
      group = 'Examples',
      order = 4,
      run = function()
        setVisible(true)
      end,
    })
  end,
}
