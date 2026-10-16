-- Independent child consumers keep broker inspection outages from disabling the management surface.

local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'
local details = require './details'
local adoption = require '@lunette-contracts/adoption'
local bindings = require '@lunette-contracts/bindings'
local display = require '@lunette-contracts/keyboard-display'
local drops = require '@lunette-contracts/drops'
local errors = require '@lunette-contracts/errors'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local interaction = require '@lunette-contracts/interaction'
local keyboard = require '@lunette-contracts/keyboard'
local laser = require '@lunette-contracts/laser'
local layouts = require '@lunette-contracts/layouts'
local menu = require '@lunette-contracts/menu'
local panels = require '@lunette-contracts/panels'
local placement = require '@lunette-contracts/placement'
local rules = require '@lunette-contracts/rules'
local surfaces = require '@lunette-contracts/surfaces'
local tags = require '@lunette-contracts/tags'
local theme = require '@lunette-contracts/theme'
local themes = require '@lunette-contracts/themes'
local uiHost = require '@lunette-contracts/ui-host'

local brokers = {}

export type Reader = {
  read name: string,
  inspect: (() -> inspection.Snapshot)?,
}

function brokers.watch(context: plugin.Context): { Reader }
  local readers: { Reader } = {}
  local function add<T>(name: string, capability: plugin.Capability<T>): ()
    local reader: Reader = { name = name, inspect = nil }
    readers[#readers + 1] = reader
    local child = plugin.consumer<<{}, {}>> {
      name = 'desktop/manager/inspect/' .. name,
      requires = { capability },
      init = function(childContext: plugin.Context, _settings: {}): ()
        -- Every listed service declares `inspect`; the cast lets one list hold services of different types.
        local service = (childContext:require(capability) :: any) :: inspection.Inspectable
        childContext:effect(function(): () -> ()
          reader.inspect = function(): inspection.Snapshot
            return service:inspect()
          end
          return function(): ()
            reader.inspect = nil
          end
        end)
      end,
    }
    context:child(child.definition)
  end
  add('frame', frame.capability)
  add('surfaces', surfaces.capability)
  add('bindings', bindings.capability)
  add('panels', panels.capability)
  add('focus', focus.capability)
  add('drops', drops.capability)
  add('tags', tags.capability)
  add('rules', rules.capability)
  add('placement', placement.capability)
  add('layouts', layouts.capability)
  add('adoption', adoption.capability)
  add('keyboard', keyboard.capability)
  add('keyboard-display', display.capability)
  add('laser', laser.capability)
  add('interaction', interaction.capability)
  add('errors', errors.capability)
  add('menu', menu.capability)
  add('theme', theme.capability)
  add('themes', themes.capability)
  add('ui-host', uiHost.capability)
  return readers
end

function brokers.snapshot(readers: { Reader }): { details.Broker }
  local result: { details.Broker } = {}
  for _, reader in readers do
    local inspect = reader.inspect
    local snapshot: inspection.Snapshot
    if inspect then
      local ok, value = pcall(inspect)
      snapshot = if ok then value else inspection.snapshot({}, {}, { 'Inspection failed: ' .. tostring(value) })
    else
      snapshot = inspection.snapshot({}, {}, { 'The inspection consumer has no active provider.' })
    end
    result[#result + 1] = table.freeze { name = reader.name, snapshot = snapshot }
  end
  return table.freeze(result)
end

return brokers
