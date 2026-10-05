-- Persists panel arrangements across provider outages. Unsupported files remain unchanged unless a save is forced. Drop-save failures are logged; quit-save failures are raised without vetoing quit. Custom formats can provide read and render functions.
local plugin = require '@lunette-plugin'
local arrangementContract = require '@lunette-contracts/arrangement'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local logging = require '@lunette-plugins/desktop/logging'
local format = require '@lunette-plugins/arrangement/format'
local slots = require '@lunette-plugins/arrangement/slots'
local state = require '@lunette-plugins/arrangement/state'

local arrangement = {}

export type Entry = state.Entry
export type File = state.File
export type Loaded = state.Loaded
export type Format = state.Format
export type KeyFor = state.KeyFor
export type Identified = state.Identified

local config = require '@lunette-plugins/arrangement/config'
local configured = require '@lunette-plugin/configured'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  drops = drops.capability,
  frame = frame.capability,
  panels = panels.capability,
  rules = rules.capability,
  tags = tags.capability,
}

local SAVE_KEYS: { [string]: boolean } = { force = true }

local function define(): plugin.Definition<Config>
  local made: state.State? = nil
  local madeWith: Settings? = nil
  -- Reuse state across activations with identical persistence options.
  local function stateFor(settings: Settings): state.State
    local current = made
    local previous = madeWith
    if
      current
      and previous
      and previous.file == settings.file
      and previous.format.read == settings.format.read
      and previous.format.render == settings.format.render
      and previous.keyFor == settings.keyFor
    then
      return current
    end
    local fresh = state.new { file = settings.file, format = settings.format, keyFor = settings.keyFor }
    made, madeWith = fresh, settings
    return fresh
  end
  return configured.create<<Config, Settings>>({
    name = 'desktop/persistence',
    schema = config,
    requires = required,
    provides = { arrangement = arrangementContract.capability },
    init = function(context: plugin.Context, settings: Settings, publish: plugin.Publisher): ()
      local frameService: frame.Service = context:require(frame.capability)
      local binding = stateFor(settings):bind(
        context,
        context:require(panels.capability),
        context:require(tags.capability),
        context:require(rules.capability)
      )
      local dropService: drops.Service = context:require(drops.capability)
      dropService:onDropped(context, {
        run = function(_drop: drops.Drop): ()
          if not binding:active() then
            return
          end
          local written, message = binding:save()
          if not written and message then
            logging.report(message, 'warn')
          end
        end,
      })
      frameService:onQuit(context, {
        run = function(): ()
          if not binding:active() then
            return
          end
          local written, message = binding:save()
          if not written then
            error('arrangement was not saved: ' .. tostring(message))
          end
        end,
      })
      local service: arrangementContract.Service = {
        save = function(
          _self: arrangementContract.Service,
          options: arrangementContract.SaveOptions?
        ): (boolean, string?)
          if options ~= nil then
            if type(options) ~= 'table' then
              error('arrangement save: options are a table of fields, not a ' .. type(options), 2)
            end
            plugin.rejectUnknownFields('arrangement save', options, SAVE_KEYS, 'force', 2)
          end
          return binding:save(options)
        end,
        restore = function(_self: arrangementContract.Service): number
          return binding:restore()
        end,
      }
      publish:provide(arrangementContract.capability, service)
    end,
  }).definition
end

arrangement.factory = define

arrangement.CURRENT_VERSION = format.CURRENT_VERSION
arrangement.newFile = format.newFile
arrangement.isFile = format.isFile
arrangement.isLoaded = format.isLoaded
arrangement.entries = format.entries
arrangement.read = format.read
arrangement.render = format.render
arrangement.empty = format.empty
arrangement.arrangement = format.arrangement
arrangement.fromTheFuture = format.fromTheFuture
arrangement.broken = format.broken
arrangement.defaultKey = slots.defaultKey
arrangement.FORMAT = state.FORMAT
arrangement.FILE = state.FILE

return arrangement
