-- The error stream contract. The provider owns the session's lunette.onError subscription, rate-limits
-- repeated reports, keeps a bounded history, and delivers to presenter plugins. The host logs errors
-- whatever subscribes here. See docs/dev/lua-api.md#errors-stream.

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
