-- The desktop's saved arrangement, kept across this consumer's outages.
--
-- A definition factory: each definition keeps one `@lunette-desktop/persist` state outside any activation,
-- so the loaded arrangement, held slots, and a refusal to overwrite survive a disable and enable. Each
-- activation binds the state as a rules source, saves on a drop and at quit, and provides
-- lunette/arrangement. A failed drop save is logged; a failed quit save raises without vetoing the quit.
-- Options: `file`, `format`, and `keyFor`, as persist.Dependencies describes.
local plugin = require '@lunette-plugin'
local arrangementContract = require '@lunette-contracts/arrangement'
local drops = require '@lunette-contracts/drops'
local frame = require '@lunette-contracts/frame'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local tags = require '@lunette-contracts/tags'
local logging = require '@lunette-desktop/logging'
local persist = require '@lunette-desktop/persist'

-- What a configuration gives: every option optional.
export type Config = {
  read file: string?,
  read format: {
    read read: ((unknown) -> persist.Loaded)?,
    read render: ((persist.File) -> string)?,
  }?,
  read keyFor: persist.KeyFor?,
}

export type Settings = {
  read file: string,
  read format: persist.Format,
  read keyFor: persist.KeyFor,
}

local DEFAULTS: Settings = {
  file = persist.FILE,
  format = persist.FORMAT,
  keyFor = persist.defaultKey,
}

local required: plugin.Declaration = {
  drops = drops.capability,
  frame = frame.capability,
  panels = panels.capability,
  rules = rules.capability,
  tags = tags.capability,
}

local SAVE_KEYS: { [string]: boolean } = { force = true }

local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/persistence', defaults = DEFAULTS, config = config }
  if settings.file == '' then
    error('plugin desktop/persistence: option file is a non-empty file name', 0)
  end
  return settings
end

local function define(): plugin.Definition<Config>
  local state: persist.State? = nil
  local madeWith: Settings? = nil
  -- The state is made once, from the options it was first activated with,
  -- and made again only if they change.
  local function stateFor(settings: Settings): persist.State
    local made = madeWith
    local current = state
    if
      current
      and made
      and made.file == settings.file
      and made.format.read == settings.format.read
      and made.format.render == settings.format.render
      and made.keyFor == settings.keyFor
    then
      return current
    end
    local fresh = persist.new { file = settings.file, format = settings.format, keyFor = settings.keyFor }
    state, madeWith = fresh, settings
    return fresh
  end
  return plugin.define {
    name = 'desktop/persistence',
    requires = required,
    provides = { arrangement = arrangementContract.capability },
    init = function(context: plugin.Context, config: Config, publish: plugin.Publisher): ()
      local settings = resolve(config)
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
  }
end

return define
