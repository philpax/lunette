-- Boots the UI host with pointing through the fake XR boundary and a test consumer that owns one panel.
local adapter = require '@lunette-plugin/adapter'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local vrUi = require '@testing/vr-ui'

local fixture = {}

export type State = {
  fixture: vrUi.Fixture,
  service: uiHost.Service,
  owner: adapter.Context,
  panel: uiHost.Panel,
  -- The standard kinds' constructors, when the standard kinds were loaded.
  components: uiComponents.Service?,
  -- The element the panel's root mount point submits on its next render.
  element: uiHost.Element?,
}

export type Options = {
  width: number?,
  height: number?,
  size: ('fixed' | 'content')?,
  setup: ((uiHost.Service, adapter.Context) -> ())?,
  -- Loads the standard kinds, whose bundled fonts the fake filesystem reads from the repository.
  standard: boolean?,
}

function fixture.boot(options: Options?): State
  options = options or {}
  local running = vrUi.boot {
    'theme',
    'frame',
    'surfaces',
    'drops',
    'focus',
    'interaction',
    {
      id = 'laser',
      definition = require('@lunette-plugins/input/laser').definition,
      config = { aim = { enabled = false }, triggerLock = { enabled = false } },
    },
    'desktop/pointing',
    { id = 'ui-host', definition = require('@lunette-plugins/ui/host').definition },
  }
  local state: State = { fixture = running } :: any
  local session = assert(running.session)
  local requires: { any } = { uiHost.capability }
  if options.standard then
    session:use(require('@lunette-plugins/ui/standard').definition, {})
    table.insert(requires, uiComponents.capability)
  end
  session:use(
    adapter.define {
      name = 'testing/ui-host-consumer',
      requires = requires,
      init = function(context: adapter.Context)
        state.owner = context
        state.service = context:require(uiHost.capability)
        if options.standard then
          state.components = context:require(uiComponents.capability)
        end
        if options.setup then
          options.setup(state.service, context)
        end
        state.panel = state.service:newPanel(context, {
          name = 'host-test',
          pose = lovr.math.newMat4():translate(0, 1.5, -1),
          width = options.width,
          height = options.height,
          size = options.size,
        })
        state.panel.root:bind {
          render = function()
            state.panel.root:submit(state.element)
          end,
        }
      end,
    },
    {}
  )
  return state
end

-- A column, a fixed-size leaf, a text label, a pressable box, and a composite counter.
function fixture.registerKinds(service: uiHost.Service, owner: any, log: { string }): ()
  service:registerKind(owner, {
    name = 'test/column',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { flexDirection = 'column', padding = props.padding or 0, gap = props.gap or 0 }
      end,
    },
  })
  service:registerKind(owner, {
    name = 'test/leaf',
    layout = {
      kind = 'leaf',
      style = function(props: uiHost.Props): lunette.LayoutStyle
        return { width = props.width, height = props.height }
      end,
    },
  })
  service:registerKind(owner, {
    name = 'test/text',
    layout = {
      kind = 'text',
      text = function(props: uiHost.Props): string
        return props.text
      end,
      textStyle = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutTextStyle
        local body = theme.type.body
        return { family = body.family, size = body.size, weight = body.weight }
      end,
    },
  })
  service:registerKind(owner, {
    name = 'test/button',
    layout = {
      kind = 'container',
      style = function(): lunette.LayoutStyle
        return { padding = 0.004 }
      end,
    },
    response = { lift = true, travel = true },
    elevation = 'raised',
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
      table.insert(log, `{node.key or '?'}:{event.kind}`)
      if event.kind == 'activate' then
        node:emit 'onActivate'
      elseif event.kind ~= 'hover-enter' and event.kind ~= 'hover-leave' then
        base(node, event)
      end
    end,
  })
  service:registerKind(owner, {
    name = 'test/counter',
    state = { count = 0 },
    expand = function(
      _props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      state: { read [string]: any },
      actions: uiHost.Actions
    ): uiHost.Child
      return {
        uiHost.element('test/button', {
          key = 'increment',
          onActivate = function()
            actions.setState(function(current: { read [string]: any }): { [string]: any }
              return { count = current.count + 1 }
            end)
          end,
          uiHost.element('test/text', { key = 'label', text = `count {state.count}` }),
        }),
      }
    end,
  })
end

-- Submits an element at the next commit and runs a frame.
function fixture.show(state: State, element: uiHost.Element?): ()
  state.element = element
  state.panel.root:schedule()
  state.fixture:step()
end

function fixture.geometry(state: State): vrUi.Geometry
  local width, height = state.panel:size()
  return {
    pose = state.panel:pose(),
    width = width,
    height = height,
    logicalWidth = width,
    logicalHeight = height,
    visible = true,
  }
end

-- The panel's surface as the interaction service sees it, for tests that deliver pointer events directly.
function fixture.surface(state: State): any
  local surfaces = require '@lunette-contracts/surfaces'
  local observed = assert(state.fixture.session):observe(surfaces.capability)
  for _, surface in assert(observed.service):all() do
    if surface.width == (state.panel:size()) then
      return surface
    end
  end
  error 'the panel offers no surface'
end

-- A stand-in pointer for direct surface events. It has no actuator.
function fixture.pointer(): any
  return {
    vibrate = function(): boolean
      return false
    end,
  }
end

-- Clicks the centre of the node at the key path.
function fixture.click(state: State, path: string): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local bounds = node:panelBounds()
  state.fixture:click(fixture.geometry(state), bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
end

return fixture
