-- A consumer with two text fields on a UI host panel, as local focus targets that request the shared keyboard.
local adapter = require '@lunette-plugin/adapter'
local uiHost = require '@lunette-contracts/ui-host'
local uiComponents = require '@lunette-contracts/ui-components'
local focus = require '@lunette-contracts/focus'
local ui = require '@lunette-plugins/ui/react'

local fields = {}

export type Fields = {
  owner: adapter.Context?,
  focus: focus.Service?,
  -- The fields' nodes, delivered by the host, and their committed values.
  first: uiHost.Ref,
  second: uiHost.Ref,
  values: { first: string, second: string },
}

export type Options = { read name: string, read pose: Mat4? }

function fields.new(): Fields
  return { first = { current = nil }, second = { current = nil }, values = { first = 'draft', second = '' } }
end

function fields.definition(state: Fields, options: Options): adapter.Definition<{}>
  local Form = ui.component('Fields', function(): ui.Child
    local c = ui.useComponents()
    local first, setFirst = ui.useState(state.values.first)
    local second, setSecond = ui.useState(state.values.second)
    return c.Panel {
      c.Body {
        key = 'body',
        c.TextField {
          key = 'first',
          ref = state.first,
          value = first,
          onChange = function(value: string)
            state.values.first = value
            setFirst(value)
          end,
        },
        c.TextField {
          key = 'second',
          ref = state.second,
          value = second,
          onChange = function(value: string)
            state.values.second = value
            setSecond(value)
          end,
        },
      },
    }
  end)
  return adapter.define {
    name = 'testing/display-fields',
    requires = { uiHost.capability, uiComponents.capability, focus.capability },
    init = function(context: adapter.Context)
      state.owner = context
      state.focus = context:require(focus.capability)
      local components = context:require(uiComponents.capability)
      local panel = context:require(uiHost.capability):newPanel(context, {
        name = options.name,
        width = 0.4,
        height = 0.2,
        pose = options.pose,
      })
      ui.mount(panel, Form {}, { components = components, owner = context })
    end,
  }
end

-- The node behind a field ref, once the host has committed it.
function fields.node(ref: uiHost.Ref): uiHost.Node
  local node = ref.current
  assert(node and not node.dead, 'the field is committed')
  return node
end

return fields
