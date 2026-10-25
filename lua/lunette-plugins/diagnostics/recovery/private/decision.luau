-- Decides, from one frame's observations, whether the recovery panel shows and when the composition is marked good.
-- Every function is pure: the plugin gathers the observations and applies the decision.

local decision = {}

export type Thresholds = {
  read errorFrames: number,
  read quietFrames: number,
  read healthySeconds: number,
}

export type Observation = {
  -- Toolkit capabilities that no active provider offers.
  read missing: { read [number]: string },
  -- Host error reports received since the previous frame.
  read hostErrors: number,
  -- Seconds on a monotonic clock.
  read now: number,
  -- Whether the composition differs from the one observed on the previous read.
  read changed: boolean,
}

export type State = {
  read errorStreak: number,
  read quietStreak: number,
  -- Host errors persisted for errorFrames, and have not yet stayed quiet for quietFrames.
  read failing: boolean,
  -- When the current healthy stretch under an unchanged composition began.
  read healthySince: number?,
  -- Whether the current healthy stretch has already been marked good.
  read marked: boolean,
}

export type Reason = 'missing' | 'failing'

export type Decision = {
  read state: State,
  read visible: boolean,
  read reason: Reason?,
  read markGood: boolean,
}

function decision.initial(): State
  local state: State = {
    errorStreak = 0,
    quietStreak = 0,
    failing = false,
    healthySince = nil,
    marked = false,
  }
  return table.freeze(state)
end

-- Whether a report's message is attributed to the host by one of the prefixes.
function decision.fromHost(message: string, prefixes: { read [number]: string }): boolean
  for _, prefix in prefixes do
    if prefix ~= '' and message:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

function decision.step(state: State, observation: Observation, thresholds: Thresholds): Decision
  local erring = observation.hostErrors > 0
  local errorStreak = if erring then state.errorStreak + 1 else 0
  local quietStreak = if erring then 0 else state.quietStreak + 1
  local failing = state.failing
  if errorStreak >= thresholds.errorFrames then
    failing = true
  elseif failing and quietStreak >= thresholds.quietFrames then
    failing = false
  end

  local missing = #observation.missing > 0
  local healthy = not missing and not failing and not erring
  local healthySince = state.healthySince
  local marked = state.marked
  if not healthy then
    healthySince, marked = nil, false
  elseif observation.changed or healthySince == nil then
    healthySince, marked = observation.now, false
  end

  local markGood = false
  if healthy and not marked and healthySince and observation.now - healthySince >= thresholds.healthySeconds then
    markGood, marked = true, true
  end

  local nextState: State = {
    errorStreak = errorStreak,
    quietStreak = quietStreak,
    failing = failing,
    healthySince = healthySince,
    marked = marked,
  }
  local reason: Reason? = if missing then 'missing' elseif failing then 'failing' else nil
  local result: Decision = {
    state = table.freeze(nextState),
    visible = missing or failing,
    reason = reason,
    markGood = markGood,
  }
  return table.freeze(result)
end

return decision
