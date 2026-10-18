-- Inspection copies broker metadata without executing callbacks or retaining resource handles.

local plugin = require '@lunette-plugin'

local inspection = {}

export type Kind =
  'offer'
  | 'handler'
  | 'listener'
  | 'panel'
  | 'control'
  | 'item'
  | 'visibility'
  | 'focus'
  | 'hold'
  | 'membership'
  | 'exclusion'
  | 'selection'
  | 'ruleSource'
  | 'placement'
  | 'layout'
  | 'poseSource'
  | 'producer'
  | 'adoption'
  | 'keyboard'
  | 'laser'
  | 'pointer'
  | 'override'
  | 'contribution'

export type Details = { read [string]: string | number | boolean }

export type Registration = {
  read kind: Kind,
  read source: string,
  read name: string?,
  read owner: plugin.Owner,
  read live: boolean,
  read details: Details,
}

export type Snapshot = {
  read registrations: { read [number]: Registration },
  read state: Details,
  read unobservable: { read [number]: string },
}

-- What every broker that holds owner-scoped registrations provides.
export type Inspectable = {
  read inspect: (Inspectable) -> Snapshot,
}

function inspection.registration(
  kind: Kind,
  source: string,
  owner: plugin.Owner,
  name: string?,
  live: boolean,
  details: Details?
): Registration
  return table.freeze {
    kind = kind,
    source = source,
    owner = owner,
    name = name,
    live = live,
    details = table.freeze(table.clone(details or {})),
  }
end

function inspection.snapshot(registrations: { Registration }, state: Details?, unobservable: { string }?): Snapshot
  return table.freeze {
    registrations = table.freeze(table.clone(registrations)),
    state = table.freeze(table.clone(state or {})),
    unobservable = table.freeze(table.clone(unobservable or {})),
  }
end

return inspection
