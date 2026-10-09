-- Registers owner-scoped boards and releases input sources, appearance listeners, and leases together.
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local keyboard = require '@lunette-contracts/keyboard'
local theme = require '@lunette-contracts/theme'
local board = require './board'
local create = require './instance'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/protected'
local config = require './config'

export type Settings = config.Settings

local function build(context: plugin.Context, settings: Settings): keyboard.Service
  local focusService: focus.Service = context:require(focus.capability)
  local themeService: theme.Service = context:require(theme.capability)
  local boards: { [board.Board]: keyboard.Owner } = {}
  return {
    inspect = function(_self: keyboard.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for target, owner in pairs(boards) do
        result[#result + 1] = inspection.registration(
          'keyboard',
          'keyboard.new',
          owner,
          nil,
          context:owns(owner) and not target.dead,
          { width = target.width, height = target.height, visible = target.visible, layer = target.layer }
        )
      end
      return inspection.snapshot(result, nil, { 'keyboard legends require callbacks' })
    end,
    new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
      local callback = options and options.onVisibilityChanged
      if callback ~= nil and type(callback) ~= 'function' then
        error('keyboard: onVisibilityChanged is a function', 2)
      end
      local label = 'keyboard visibility (' .. plugin.ownerLabel(owner) .. ')'
      local function active(): boolean
        return context:active() and context:owns(owner)
      end
      local function notify(change: keyboard.VisibilityChange): ()
        local run = callback
        if change.reason == 'destroy' then
          callback = nil
        end
        if run then
          protected.call(label, function(): ()
            run(change)
          end)
        end
      end
      local cleanupEffect: plugin.Effect? = nil
      local result, acquired = context:resource(owner, function(): (board.Board, () -> ())
        -- Each disposer is pushed as its resource is acquired, so a failed construction and a destroy release the same list.
        local disposers: { () -> () } = {}
        local function disposeAll(failures: { string }): { string }
          for index = #disposers, 1, -1 do
            local ok, failure = pcall(disposers[index])
            if not ok then
              failures[#failures + 1] = tostring(failure)
            end
          end
          table.clear(disposers)
          return failures
        end
        local made: board.Board? = nil
        local ok, failure = pcall(function(): ()
          local source = focusService:newSource(context, { mode = 'virtual' })
          table.insert(disposers, function(): ()
            source:destroy()
          end)
          local created, destroyState, clearInput, refresh = create(
            settings,
            source,
            themeService,
            active,
            notify,
            function(): ()
              local effect = cleanupEffect
              cleanupEffect = nil
              if effect then
                effect:dispose()
              end
            end
          )
          made = created
          table.insert(disposers, destroyState)
          local changed = focusService:onChanged(context, {
            run = function(_change: focus.Change): ()
              if not created.dead then
                clearInput()
              end
            end,
          })
          table.insert(disposers, function(): ()
            changed:dispose()
          end)
          local themeChanged = themeService:onChanged(context, {
            run = function(_snapshot: theme.Snapshot): ()
              refresh()
            end,
          })
          table.insert(disposers, function(): ()
            themeChanged:dispose()
          end)
          boards[created] = owner
        end)
        if not ok then
          callback = nil
          error(table.concat(disposeAll { tostring(failure) }, '\n'), 0)
        end
        local created = made :: board.Board
        return created,
          function(): ()
            if created.dead then
              return
            end
            boards[created] = nil
            cleanupEffect = nil
            local failures = disposeAll {}
            notify { visible = false, reason = 'destroy' }
            if #failures > 0 then
              error(table.concat(failures, '\n'), 0)
            end
          end
      end)
      if not result.dead then
        cleanupEffect = acquired
      end
      return result
    end,
  }
end

return build
