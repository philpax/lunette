-- Boots the UI host with pointing through the fake XR boundary and a test consumer that owns one panel.
local adapter = require '@lunette-plugin/adapter'
local uiHost = require '@lunette-contracts/ui-host'
local vrUi = require '@testing/vr-ui'

local fixture = {}

export type State = {
  fixture: vrUi.Fixture,
  service: uiHost.Service,
  owner: adapter.Context,
  panel: uiHost.Panel,
  -- The element the panel's root mount point submits on its next render.
  element: uiHost.Element?,
}

export type Options = {
  width: number?,
  height: number?,
  size: ('fixed' | 'content')?,
  setup: ((uiHost.Service, adapter.Context) -> ())?,
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
  running.session:use(
    adapter.define {
      name = 'testing/ui-host-consumer',
      requires = { uiHost.capability },
      init = function(context: adapter.Context)
        state.owner = context
        state.service = context:require(uiHost.capability)
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

-- Clicks the centre of the node at the key path.
function fixture.click(state: State, path: string): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local bounds = node:panelBounds()
  state.fixture:click(fixture.geometry(state), bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
end

return fixture
