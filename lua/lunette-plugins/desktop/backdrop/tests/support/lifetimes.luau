-- Uses shipped providers and public service observers for backdrop lifetime tests.
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local management = require '@lunette-plugin/management'
local frames = require '@lunette-plugins/frame'
local backdrop = require '@lunette-plugins/desktop/backdrop'
local testing = require '@testing'
local frame = require '@lunette-contracts/frame'
local menu = require '@lunette-contracts/menu'
local ui = require '@lunette-contracts/ui'
local panels = require '@lunette-contracts/panels'
local surfaces = require '@lunette-contracts/surfaces'
local composition = require '@lunette-contracts/composition'

export type Services = {
  frame: frame.Service?,
  menu: menu.Service?,
  ui: ui.Service?,
  panels: panels.Service?,
  surfaces: surfaces.Service?,
  composition: composition.Service?,
}
export type Observers = {
  frame: testing.Observed<frame.Service>,
  menu: testing.Observed<menu.Service>,
  ui: testing.Observed<ui.Service>,
  panels: testing.Observed<panels.Service>,
  surfaces: testing.Observed<surfaces.Service>,
}

local lifetimes = {}
local capabilities = {
  frame = frame.capability,
  menu = menu.capability,
  ui = ui.capability,
  panels = panels.capability,
  surfaces = surfaces.capability,
}

function lifetimes.entries(): { plugin.Entry }
  local entries = {}
  for _, id in
    {
      'frame',
      'theme',
      'surfaces',
      'panels',
      'drops',
      'focus',
      'interaction',
      'laser',
      'ui',
      'menu',
      'audio',
      'audio-analysis',
      'desktop/pointing',
    }
  do
    entries[#entries + 1] = { id = id, definition = require('@lunette-plugins/' .. id).definition }
  end
  entries[#entries + 1] = { id = 'desktop/backdrop', definition = backdrop.create().definition }
  return plugin.compose(entries)
end

function lifetimes.observe(session: testing.Session): Observers
  local observed = {}
  for name, capability in capabilities do
    observed[name] = session:observe(capability)
  end
  return observed
end

function lifetimes.run()
  local services = {}
  local entries = table.clone(lifetimes.entries())
  local required = table.clone(capabilities)
  required.composition = composition.capability
  for name, capability in required do
    entries[#entries + 1] = {
      id = 'testing/backdrop-observer-' .. name,
      definition = adapter.define {
        name = 'testing/backdrop-observer-' .. name,
        requires = { capability },
        init = function(context: plugin.Context)
          services[name] = context:require(capability)
          context:effect(function(): plugin.Effect
            return function()
              services[name] = nil
            end
          end)
        end,
      },
    }
  end
  local running
  frames.install {
    start = function()
      if not running then
        running = management.start(entries)
        _G.backdropReloadServices = services
      end
    end,
    stop = function()
      if running then
        running.runtime:close()
        running = nil
      end
      _G.backdropReloadServices = nil
    end,
  }
end

return lifetimes
