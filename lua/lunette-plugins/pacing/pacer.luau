-- The pacer selects a frame rate from window visibility, content type, and observed commits.
-- See docs/dev/rendering.md for the default rates.

local contract = require '@lunette-contracts/pacing'

local pacer = {}

export type ContentType = contract.ContentType
export type Observation = contract.Observation
export type Pacer = contract.Pacer

-- Content types that remain exempt regardless of observed commit rate.
export type ExemptTypes = {
  read none: boolean,
  read photo: boolean,
  read video: boolean,
  read game: boolean,
}

export type Tuning = {
  read background: number,
  read exempt: number,
  read history: number,
  read busy: number,
  read exemptTypes: ExemptTypes,
}

-- A window in view is unthrottled, because the compositor already skips undamaged surfaces; out of view, an
-- exempt window runs at `exempt` and any other at `background`. An empty history does not indicate idle
-- content, so a new video player remains unthrottled until it has observations.
function pacer.new(tuning: Tuning): Pacer
  local exemptTypes: { [string]: boolean } = tuning.exemptTypes :: any
  -- Unfilled history slots differ from recorded frames without commits.
  local samples: { boolean } = {}
  local nextSlot = 1
  local committed = 0

  local function record(drew: boolean): ()
    if samples[nextSlot] then
      committed -= 1
    end
    samples[nextSlot] = drew
    if drew then
      committed += 1
    end
    nextSlot = nextSlot % tuning.history + 1
  end

  -- The content hint identifies paused video; commit history identifies clients without a hint.
  local function isExempt(contentType: ContentType?): boolean
    if contentType ~= nil and exemptTypes[contentType] then
      return true
    end
    return #samples > 0 and committed / #samples >= tuning.busy
  end

  return table.freeze {
    -- An observation without `drew` adds no sample because a throttled client cannot report a quiet frame.
    observe = function(_self: Pacer, observation: Observation): number?
      local drew = observation.drew
      if drew ~= nil then
        record(drew == true)
      end
      if observation.visible then
        return nil
      elseif isExempt(observation.contentType) then
        return tuning.exempt
      end
      return tuning.background
    end,
  }
end

return pacer
