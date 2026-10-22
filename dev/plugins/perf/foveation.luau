-- Applies and saves the foveation level and the density overlay, and restores the headset's previous state when the
-- context ends. Support is known only from a call that returned false: disabling foveation and disabling the overlay
-- succeed even where neither is supported, so only a level other than 'none' or enabling the overlay can report it.
local plugin = require '@lunette-plugin'

local foveation = {}

export type Level = 'none' | 'low' | 'medium' | 'high'

foveation.LEVELS = table.freeze { 'none', 'low', 'medium', 'high' } :: { Level }

-- The headset calls the controller makes, so tests substitute a fake.
export type Headset = {
  read getFoveation: () -> (Level, boolean),
  read setFoveation: (Level, boolean) -> boolean,
  read getFoveationOverlay: () -> boolean,
  read setFoveationOverlay: (boolean) -> boolean,
}

-- The requested settings, and whether the headset refused them.
export type Status = {
  read level: Level,
  read overlay: boolean,
  read levelUnavailable: boolean,
  read overlayUnavailable: boolean,
}

export type Controller = {
  read status: (Controller) -> Status,
  read setLevel: (Controller, Level) -> Status,
  read setOverlay: (Controller, boolean) -> Status,
}

function foveation.headset(): Headset
  return table.freeze {
    getFoveation = function(): (Level, boolean)
      return lovr.headset.getFoveation()
    end,
    setFoveation = function(level: Level, dynamic: boolean): boolean
      if level == 'none' then
        return lovr.headset.setFoveation()
      end
      return lovr.headset.setFoveation(level, dynamic)
    end,
    getFoveationOverlay = function(): boolean
      return lovr.headset.getFoveationOverlay()
    end,
    setFoveationOverlay = function(enabled: boolean): boolean
      return lovr.headset.setFoveationOverlay(enabled)
    end,
  }
end

function foveation.attach(
  context: plugin.Context,
  headset: Headset,
  initial: { read level: Level, read overlay: boolean }
): Controller
  context:effect(function(): () -> ()
    local level, dynamic = headset.getFoveation()
    local overlay = headset.getFoveationOverlay()
    return function(): ()
      headset.setFoveation(level, dynamic)
      headset.setFoveationOverlay(overlay)
    end
  end)
  local status: Status =
    { level = initial.level, overlay = initial.overlay, levelUnavailable = false, overlayUnavailable = false }
  -- Fixed foveation: a dynamic level follows the runtime's load heuristics, which would hide what a level costs.
  local function applyLevel(level: Level): ()
    local applied = headset.setFoveation(level, false)
    status = {
      level = level,
      overlay = status.overlay,
      levelUnavailable = if level == 'none' then status.levelUnavailable else not applied,
      overlayUnavailable = status.overlayUnavailable,
    }
  end
  local function applyOverlay(enabled: boolean): ()
    local applied = headset.setFoveationOverlay(enabled)
    status = {
      level = status.level,
      overlay = enabled,
      levelUnavailable = status.levelUnavailable,
      overlayUnavailable = if enabled then not applied else status.overlayUnavailable,
    }
  end
  applyLevel(initial.level)
  applyOverlay(initial.overlay)
  return table.freeze {
    status = function(_self: Controller): Status
      return status
    end,
    setLevel = function(_self: Controller, level: Level): Status
      if level ~= status.level then
        applyLevel(level)
        context:save { foveation = level }
      end
      return status
    end,
    setOverlay = function(_self: Controller, enabled: boolean): Status
      if enabled ~= status.overlay then
        applyOverlay(enabled)
        context:save { overlay = enabled }
      end
      return status
    end,
  }
end

return foveation
