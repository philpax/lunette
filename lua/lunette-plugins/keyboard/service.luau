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

local function settingsFor(settings: Settings, options: keyboard.Options?): Settings
  if not options or (options.rows == nil and options.layers == nil) then
    return settings
  end
  return config.resolve({ rows = options.rows, layers = options.layers }, settings, 'keyboard')
end

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
      local own = settingsFor(settings, options)
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
        local source = focusService:newSource(context, { mode = 'virtual' })
        local changed: plugin.Effect? = nil
        local themeChanged: plugin.Effect? = nil
        local made: board.Board? = nil
        local destroyBoard: (() -> ())? = nil
        local ok, failure = pcall(function(): ()
          local created, destroyState, clearInput, refresh = create(
            own,
            options,
            source,
            themeService,
            context,
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
          made, destroyBoard = created, destroyState
          changed = focusService:onChanged(context, {
            run = function(_change: focus.Change): ()
              if not created.dead then
                clearInput()
              end
            end,
          })
          themeChanged = themeService:onChanged(context, function(_snapshot: theme.Snapshot): ()
            refresh()
          end)
          boards[created] = owner
        end)
        if not ok then
          callback = nil
          local failures = { tostring(failure) }
          local function cleanup(run: () -> ()): ()
            local cleaned, cleanupFailure = pcall(run)
            if not cleaned then
              failures[#failures + 1] = tostring(cleanupFailure)
            end
          end
          if destroyBoard then
            cleanup(destroyBoard)
          end
          local themeEffect = themeChanged
          themeChanged = nil
          if themeEffect then
            cleanup(function(): ()
              themeEffect:dispose()
            end)
          end
          local effect = changed
          changed = nil
          if effect then
            cleanup(function(): ()
              effect:dispose()
            end)
          end
          cleanup(function(): ()
            source:destroy()
          end)
          error(table.concat(failures, '\n'), 0)
        end
        local created, destroyState = made :: board.Board, destroyBoard :: () -> ()
        return created,
          function(): ()
            if created.dead then
              return
            end
            boards[created] = nil
            cleanupEffect = nil
            local effect = changed
            changed = nil
            local themeEffect = themeChanged
            themeChanged = nil
            local failures: { string } = {}
            local ended, endFailure = pcall(destroyState)
            if not ended then
              failures[#failures + 1] = tostring(endFailure)
            end
            if themeEffect then
              local cleaned, failure = pcall(function(): ()
                themeEffect:dispose()
              end)
              if not cleaned then
                failures[#failures + 1] = tostring(failure)
              end
            end
            if effect then
              local cleaned, failure = pcall(function(): ()
                effect:dispose()
              end)
              if not cleaned then
                failures[#failures + 1] = tostring(failure)
              end
            end
            local cleaned, failure = pcall(function(): ()
              source:destroy()
            end)
            if not cleaned then
              failures[#failures + 1] = tostring(failure)
            end
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
