-- The error stream contract.
--
-- The provider owns the session's lunette.onError subscription for its
-- activation, rate-limits repeated reports, and keeps a bounded history of
-- what it delivered. Presenters are ordinary plugins that subscribe: a panel
-- in the scene, a toast, a desktop notification, or a sound. Several may
-- subscribe at once, and none of them needs to know about the others. Native
-- errors are always logged by the host, whatever subscribes here; disabling
-- the provider removes only their presentation and rate limiting.
--
-- A report is delivered to every subscriber, in subscription order, each
-- under its own protected call; a subscriber that raises is reported once
-- more through lunette.reportError, which this provider then rate-limits like
-- any other report. A repeated report within the provider's window is
-- withheld and counted, and the next delivery of it carries how many were
-- withheld. subscribe is owner-scoped. clear forgets the history and tells
-- every subscriber, so a presenter showing a report can stop showing it.

local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'

local errors = {}

export type Owner = owner.Owner

-- One delivered report. `text` is the message, the traceback, and a note of
-- the withheld repeats, ready to show; `sequence` counts the reports
-- delivered since the provider started or was last cleared, this one
-- included; and `time` is the provider's clock when it arrived.
export type Report = {
  read message: string,
  read traceback: string,
  read suppressed: number,
  read text: string,
  read sequence: number,
  read time: number,
}

-- What subscribe takes: what runs for each report, and what runs when the
-- history is cleared.
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
