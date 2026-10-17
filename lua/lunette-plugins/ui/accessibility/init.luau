-- Provides the session's accessibility settings as a store, saved as the entry's saved settings on every change, and
-- relays announcements to assistive plugins.

local plugin = require '@lunette-plugin'
local accessibility = require '@lunette-contracts/accessibility'
local uiHost = require '@lunette-contracts/ui-host'
local inspection = require '@lunette-contracts/inspection'
local listeners = require '@lunette-plugins/registration/listeners'
local ui = require '@lunette-plugins/ui/react'
local config = require '@self/config'

export type Config = config.Config
export type Settings = config.Settings

local function build(context: plugin.Context, options: Settings): accessibility.Service
  local store = ui.store(table.freeze(table.clone(options)) :: accessibility.Settings)
  -- The toolkit host applies the settings it understands; they reach it now and after each change.
  local host = context:require(uiHost.capability)
  local function apply(settings: accessibility.Settings): ()
    host:setAccessibility {
      textScale = settings.textScale,
      highContrast = settings.highContrast,
      reducedMotion = settings.reducedMotion,
      haptics = settings.haptics,
    }
  end
  apply(store:get())
  local unsubscribe = store:subscribe(apply)
  context:effect(function(): () -> ()
    return unsubscribe
  end)
  local announcements = listeners.new<<accessibility.Listener>>(context)

  local service: accessibility.Service = {
    settings = store :: any,
    update = function(_self: accessibility.Service, changes: { [string]: any }): ()
      assert(type(changes) == 'table', 'accessibility: changes are a table of settings')
      local next = table.clone(store:get()) :: { [string]: any }
      for name, value in changes do
        local valid = type(name) == 'string' and pcall(config.schema.parse, { [name] = value }, 'accessibility')
        assert(valid, `accessibility: {tostring(value)} is not a valid {tostring(name)}`)
        next[name] = value
      end
      store:set(table.freeze(next) :: accessibility.Settings)
      context:save(changes)
    end,
    announce = function(
      _self: accessibility.Service,
      owner: plugin.Owner,
      announcement: accessibility.Announcement
    ): ()
      context:checkOwner(owner)
      assert(
        type(announcement) == 'table' and type(announcement.text) == 'string',
        'accessibility: an announcement has text'
      )
      announcements:each('accessibility: announcement listener', function(listener: accessibility.Listener): ()
        listener.run(announcement)
      end)
    end,
    onAnnouncement = function(
      _self: accessibility.Service,
      owner: plugin.Owner,
      listener: accessibility.Listener
    ): plugin.Effect
      context:checkOwner(owner)
      listeners.check('accessibility onAnnouncement', listener)
      return announcements:add(owner, listener)
    end,
    inspect = function(_self: accessibility.Service): inspection.Snapshot
      local state: { [string]: string | number | boolean } = {}
      for name, value in store:get() :: any do
        state[name] = value
      end
      return inspection.snapshot({}, state)
    end,
  }
  return service
end

return plugin.provider<<Config, Settings, accessibility.Service>> {
  name = 'accessibility',
  schema = config.schema,
  capability = accessibility.capability,
  requires = { uiHost.capability },
  build = build,
}
