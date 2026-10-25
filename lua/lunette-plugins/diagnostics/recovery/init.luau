-- Keeps the session operable in VR when the UI toolkit fails. It requires none of the toolkit's capabilities: it
-- reads the composition and the error stream, draws its own panel, and offers it for ray picking. See README.md.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local composition = require '@lunette-contracts/composition'
local errors = require '@lunette-contracts/errors'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local uiHost = require '@lunette-contracts/ui-host'
local config = require '@self/config'
local decision = require '@self/private/decision'
local layout = require '@self/private/layout'
local panels = require '@self/private/panel'
local restore = require '@self/private/restore'

export type Config = config.Config
export type Settings = config.Settings

local required: plugin.Declaration = {
  composition.capability,
  errors.capability,
  frame.capability,
  surfaces.capability,
}

local function describe(reason: decision.Reason?, missing: { read [number]: string }): string
  if reason == 'missing' then
    local names: { string } = {}
    for _, name in missing do
      names[#names + 1] = name
    end
    return 'The UI toolkit is not running: ' .. table.concat(names, ', ') .. ' has no active provider.'
  end
  return 'The UI host reports errors on every frame.'
end

local function init(context: plugin.Context, settings: Settings): ()
  local compositionService = context:require(composition.capability)
  local frameService = context:require(frame.capability)
  local surfaceService = context:require(surfaces.capability)
  local stream = context:require(errors.capability)
  local host = plugin.connectOptional(context, 'diagnostics/recovery/appearance', uiHost.capability)

  local state = decision.initial()
  local reason: decision.Reason? = nil
  local missing: { read [number]: string } = {}
  local previous: composition.Observation? = nil
  local untilPoll = 0
  local hostErrors = 0
  local recent: { string } = {}
  local status: string? = nil

  local function remember(message: string): ()
    table.insert(recent, 1, message)
    while #recent > settings.recentErrors do
      table.remove(recent)
    end
  end
  local latest = stream:latest()
  if latest then
    remember(latest.message)
  end
  stream:onReport(context, {
    run = function(report: errors.Report): ()
      remember(report.message)
    end,
  })
  -- The stream suppresses repeats, so persistence is counted from every native report.
  context:on {
    event = lunette.onError,
    run = function(event: lunette.ErrorEvent): ()
      if decision.fromHost(tostring(event.message), settings.hostErrorPrefixes) then
        hostErrors += 1
      end
    end,
  }

  local function actions(): { layout.Action }
    local connection = host()
    local service = if connection then connection.service else nil
    local appearance: layout.Action = if service
      then {
        id = 'appearance',
        label = if service:defaultAppearance() then 'Leave default appearance' else 'Use default appearance',
        enabled = true,
      }
      else {
        id = 'appearance',
        label = 'Use default appearance',
        enabled = false,
        note = 'The UI host is not running.',
      }
    local restorable: layout.Action = if compositionService:lastGood()
      then { id = 'restore', label = 'Restore the last known good configuration', enabled = true }
      else {
        id = 'restore',
        label = 'Restore the last known good configuration',
        enabled = false,
        note = 'No configuration has stayed healthy long enough to be recorded.',
      }
    local applying = false
    for _, setting in compositionService:savedSettings() do
      applying = applying or setting.status == 'applied'
    end
    local withoutSaved: layout.Action = {
      id = 'without-saved',
      label = 'Set saved settings aside',
      enabled = applying,
      note = if applying then nil else 'No saved settings apply.',
    }
    return {
      appearance,
      { id = 'reload', label = 'Reload configuration', enabled = true },
      restorable,
      withoutSaved,
      { id = 'safe-mode', label = 'Restart into safe mode', enabled = true },
    }
  end

  local function content(): layout.Content
    return { reason = describe(reason, missing), errors = recent, status = status, actions = actions() }
  end

  local function applyGood(): ()
    local good = compositionService:lastGood()
    if not good then
      status = 'No configuration has been recorded as good.'
      return
    end
    local operations = restore.plan(compositionService:entries(), good.entries)
    local failures: { string } = {}
    for _, operation in operations do
      local ok, problem = pcall(function(): ()
        if operation.kind == 'disable' then
          compositionService:disable(operation.id)
        elseif operation.kind == 'enable' then
          compositionService:enable(operation.id)
        elseif operation.kind == 'configure' then
          compositionService:configure(operation.id, operation.config)
        elseif operation.kind == 'restore' then
          compositionService:restore(operation.id)
          for _, entry in compositionService:entries() do
            if entry.id == operation.id and not restore.equal(entry.config, operation.config) then
              compositionService:configure(operation.id, operation.config)
            end
          end
        end
      end)
      if not ok then
        failures[#failures + 1] = tostring(problem)
        lunette.reportError {
          context = `recovery: {operation.kind} {operation.id}`,
          message = tostring(problem),
        }
      end
    end
    status = if #operations == 0
      then 'The configuration already matches the last known good one.'
      elseif #failures == 0 then `Restored the last known good configuration with {#operations} changes.`
      else `Restored with {#failures} of {#operations} changes failing: {failures[1]}`
  end

  local function activate(id: layout.ActionId): ()
    if id == 'appearance' then
      local connection = host()
      if connection then
        local service = connection.service
        local on = not service:defaultAppearance()
        service:setDefaultAppearance(on)
        status = if on then 'Default appearance is on.' else 'Default appearance is off.'
      end
    elseif id == 'reload' then
      status = 'Reloading the configuration.'
      local reloaded, message = lunette.reload()
      if not reloaded then
        status = 'The configuration did not reload: ' .. tostring(message)
      end
    elseif id == 'restore' then
      applyGood()
    elseif id == 'without-saved' then
      -- The saved settings stay in the file, so the runtime manager's Saved tab can forget the one at fault.
      local returned = compositionService:suspendSaved()
      status =
        `Set saved settings aside for {returned} entr{if returned == 1 then 'y' else 'ies'} until the next start.`
    elseif id == 'safe-mode' then
      local requested, message = lunette.restartIntoSafeMode()
      status = if requested then 'Restarting into safe mode.' else 'Safe mode is unavailable: ' .. tostring(message)
    end
  end

  local panel = panels.new(settings, {
    activate = activate,
    live = function(): boolean
      return context:active()
    end,
  })
  context:effect(function(): () -> ()
    return function(): ()
      panel:dispose()
    end
  end)
  surfaceService:offer(context, {
    name = 'diagnostics/recovery',
    list = function(): { surfaces.Surface }
      return if panel:visible() then { panel.surface } else {}
    end,
  })

  frameService:onUpdate(context, {
    phase = 'scene',
    run = function(dt: number): ()
      local changed = false
      untilPoll -= dt
      if untilPoll <= 0 then
        untilPoll = settings.pollSeconds
        local observation = compositionService:observe(settings.toolkit)
        missing = observation.missing
        changed = previous ~= nil
          and previous.revision ~= observation.revision
          and not restore.same(previous.entries, observation.entries)
        previous = observation
      end
      local result = decision.step(state, {
        missing = missing,
        hostErrors = hostErrors,
        now = lovr.timer.getTime(),
        changed = changed,
      }, settings)
      hostErrors = 0
      state = result.state
      reason = result.reason
      if result.markGood then
        -- A mark refused while the runtime drains is tried again on a later frame of the same healthy stretch.
        local marked = pcall(compositionService.markGood, compositionService)
        if not marked then
          local retry = table.clone(state) :: any
          retry.marked = false
          state = table.freeze(retry)
        end
      end
      if result.visible then
        panel:show(content())
      else
        panel:hide()
        status = nil
      end
    end,
  })
  frameService:onDraw(context, {
    phase = 'overlay',
    run = function(pass: Pass): ()
      panel:draw(pass)
    end,
  })
end

return plugin.consumer<<Config, Settings>> {
  name = 'diagnostics/recovery',
  requires = required,
  schema = config.schema,
  init = init,
}
