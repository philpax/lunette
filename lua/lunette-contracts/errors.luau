-- The error stream rate-limits repeated reports, stores bounded history, and notifies subscribers. The host logs errors independently.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local errors = {}

export type Owner = owner.Owner

-- `sequence` counts delivered reports since the provider started or was cleared. `time` records when the provider received the report.
export type Report = {
  read message: string,
  read traceback: string,
  read suppressed: number,
  read text: string,
  read sequence: number,
  read time: number,
}

export type Subscriber = {
  read run: (Report) -> (),
  read cleared: (() -> ())?,
}

export type Service = {
  read subscribe: (Service, Owner, Subscriber) -> plugin.Effect,
  read recent: (Service) -> { Report },
  read clear: (Service, Owner) -> (),
}

export type Capability = plugin.Capability<Service>

errors.capability = plugin.capability<<Service>> { name = 'lunette/errors', schema = 1 }

return errors
