-- The error stream rate-limits repeated reports, stores bounded history, and notifies listeners. The host logs errors independently.

local plugin = require '@lunette-plugin'

local errors = {}

export type Owner = plugin.Owner

-- `sequence` counts delivered reports since the provider started.
export type Report = {
  read message: string,
  read traceback: string,
  read suppressed: number,
  read text: string,
  read sequence: number,
}

export type Listener = {
  read run: (Report) -> (),
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read onReport: (Service, Owner, Listener) -> plugin.Effect,
  read recent: (Service) -> { Report },
}

export type Capability = plugin.Capability<Service>

errors.capability = plugin.capability<<Service>> { name = 'lunette/errors', version = 1 }

return errors
