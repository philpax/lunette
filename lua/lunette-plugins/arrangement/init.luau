-- Persists panel arrangements across provider outages. Drop-save failures are logged, and quit-save
-- failures are raised without vetoing quit.

local plugin = require '@lunette-plugin'
local arrangementContract = require '@lunette-contracts/arrangement'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local logging = require '@lunette-plugins/desktop/logging'
local state = require '@lunette-plugins/arrangement/state'
local config = require '@lunette-plugins/arrangement/config'

local arrangement = {}

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  drops.capability,
  frame.capability,
  panels.capability,
  rules.capability,
  tags.capability,
}

local function define(): plugin.Definition<Config>
  local made: state.State? = nil
  local madeFor: string? = nil
  -- State is reused across activations with the same file, so held slots survive provider outages.
  local function stateFor(settings: Settings): state.State
    local current = made
    if current and madeFor == settings.file then
      return current
    end
    local fresh = state.new(settings.file)
    made, madeFor = fresh, settings.file
    return fresh
  end
  return plugin.provider<<Config, Settings, arrangementContract.Service>>({
    name = 'desktop/persistence',
    capability = arrangementContract.capability,
    schema = config.schema,
    requires = required,
    build = function(context: plugin.Context, settings: Settings): arrangementContract.Service
      local service = stateFor(settings):bind(
        context,
        context:require(panels.capability),
        context:require(tags.capability),
        context:require(rules.capability)
      )
      local dropService: drops.Service = context:require(drops.capability)
      dropService:onDropped(context, {
        run = function(_drop: drops.Drop): ()
          local written, message = service:save()
          if not written and message then
            logging.report(message, 'warn')
          end
        end,
      })
      local frameService: frame.Service = context:require(frame.capability)
      frameService:onQuit(context, {
        run = function(): ()
          local written, message = service:save()
          if not written then
            error('arrangement was not saved: ' .. tostring(message))
          end
        end,
      })
      return service
    end,
  }).definition
end

arrangement.definition = define

return arrangement
