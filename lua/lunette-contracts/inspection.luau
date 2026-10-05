-- Inspection copies broker metadata without executing callbacks or retaining resource handles.

local plugin = require '@lunette-plugin'

local inspection = {}

export type Kind =
  'offer'
  | 'handler'
  | 'listener'
  | 'panel'
  | 'visibility'
  | 'focus'
  | 'tag'
  | 'hold'
  | 'membership'
  | 'exclusion'
  | 'selection'
  | 'layoutChoice'
  | 'ruleSource'
  | 'placement'
  | 'layout'
  | 'poseSource'
  | 'producer'
  | 'adoption'
  | 'keyboard'
  | 'laser'
  | 'pointer'

export type Details = { read [string]: string | number | boolean }

export type Registration = {
  read kind: Kind,
  read source: string,
  read name: string?,
  read owner: plugin.Owner,
  read live: boolean,
  read dead: boolean,
  read details: Details,
}

export type Snapshot = {
  read registrations: { read [number]: Registration },
  -- Logical registrations are not native effects; one registration can acquire several effects.
  read logicalRegistrationCount: number,
  read state: Details,
  read unobservable: { read [number]: string },
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
    dead = not live,
    details = table.freeze(table.clone(details or {})),
  }
end

function inspection.snapshot(registrations: { Registration }, state: Details?, unobservable: { string }?): Snapshot
  local copies: { Registration } = {}
  for index, entry in ipairs(registrations) do
    copies[index] =
      inspection.registration(entry.kind, entry.source, entry.owner, entry.name, entry.live, entry.details)
  end
  return table.freeze {
    registrations = table.freeze(copies),
    logicalRegistrationCount = #copies,
    state = table.freeze(table.clone(state or {})),
    unobservable = table.freeze(table.clone(unobservable or {})),
  }
end

return inspection
