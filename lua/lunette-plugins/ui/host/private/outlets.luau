-- Outlet contributions and declarations. A contribution lives for its owner's lifetime under the name of the outlet it
-- contributes to, and every live contribution and placement holds its outlet's declaration, so a second declaration
-- of a name and version with a different schema is rejected while the first is in use.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'

local outlets = {}

export type Outlets = {
  -- Live contributions per outlet name, in the order they were made.
  contributions: { [string]: { records.Contribution } },
  -- The live declarations per name and version, with the schema each declares and the number of contributions and
  -- placements that hold it.
  declarations: { [string]: { metadata: unknown, holders: number } },
  placements: { records.Placement },
  sequence: number,
}

local CONTRIBUTION_FIELDS: { [string]: boolean } = { version = true, bind = true }

function outlets.new(): Outlets
  return { contributions = {}, declarations = {}, placements = {}, sequence = 0 }
end

-- Whether a contribution built against one version works at a placement of another: the same major version, and a
-- minor version no higher than the placement's.
function outlets.compatible(built: uiHost.Version, offered: uiHost.Version): boolean
  return built.major == offered.major and built.minor <= offered.minor
end

function outlets.versionText(version: uiHost.Version): string
  return `{version.major}.{version.minor}`
end

local versionText = outlets.versionText

local function wholeNumber(value: unknown): boolean
  return type(value) == 'number' and value >= 0 and value == math.floor(value) and value < math.huge
end

-- Asserts that a value is an outlet declaration, as `uiHost.outlet` makes one.
function outlets.check(outlet: unknown): uiHost.Outlet<any>
  local value = outlet :: any
  assert(type(value) == 'table' and type(value.name) == 'string', 'ui: an outlet is declared with uiHost.outlet')
  local version = value.version
  assert(
    type(version) == 'table' and wholeNumber(version.major) and wholeNumber(version.minor),
    `ui: the outlet {value.name} has a version of whole major and minor numbers`
  )
  local props = value.props
  assert(
    type(props) == 'table' and type(props.parse) == 'function' and type(props.inspect) == 'function',
    `ui: the outlet {value.name} has a props schema`
  )
  return value :: uiHost.Outlet<any>
end

-- Schemas compare by their metadata. Validation functions compare equal, because a contract module that is
-- required again makes new ones for the same schema.
local function same(first: unknown, second: unknown): boolean
  if first == second then
    return true
  end
  if type(first) == 'function' and type(second) == 'function' then
    return true
  end
  if type(first) ~= 'table' or type(second) ~= 'table' then
    return false
  end
  local left, right = first :: { [unknown]: unknown }, second :: { [unknown]: unknown }
  for key, value in left do
    if not same(value, right[key]) then
      return false
    end
  end
  for key in right do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function declarationKey(outlet: uiHost.Outlet<any>): string
  return `{outlet.name}@{versionText(outlet.version)}`
end

-- Holds a declaration, answering false when a live declaration of the same name and version has another schema.
function outlets.hold(target: Outlets, outlet: uiHost.Outlet<any>): boolean
  local key = declarationKey(outlet)
  local metadata = outlet.props.inspect()
  local existing = target.declarations[key]
  if existing then
    if not same(existing.metadata, metadata) then
      return false
    end
    existing.holders += 1
  else
    target.declarations[key] = { metadata = metadata, holders = 1 }
  end
  return true
end

function outlets.release(target: Outlets, outlet: uiHost.Outlet<any>): ()
  local key = declarationKey(outlet)
  local existing = target.declarations[key]
  if existing then
    existing.holders -= 1
    if existing.holders <= 0 then
      target.declarations[key] = nil
    end
  end
end

-- Validates a contribution to an outlet before it is added, answering the version it is built against. It raises
-- for a version the outlet's cannot accept and for a schema that conflicts with a live declaration.
function outlets.prepare(target: Outlets, outlet: uiHost.Outlet<any>, contribution: uiHost.Contribution): uiHost.Version
  outlets.check(outlet)
  assert(type(contribution) == 'table', 'ui: a contribution is a table')
  for field in contribution :: any do
    assert(CONTRIBUTION_FIELDS[field], `ui: '{tostring(field)}' is not a contribution field`)
  end
  assert(type(contribution.bind) == 'function', 'ui: a contribution binds mount points with a function')
  local version = contribution.version or outlet.version
  assert(
    type(version) == 'table' and wholeNumber(version.major) and wholeNumber(version.minor),
    'ui: a contribution has a version of whole major and minor numbers'
  )
  assert(
    outlets.compatible(version, outlet.version),
    `ui: a contribution built against version {versionText(version)} of the outlet {outlet.name} cannot render at `
      .. `version {versionText(outlet.version)}`
  )
  local existing = target.declarations[declarationKey(outlet)]
  assert(
    existing == nil or same(existing.metadata, outlet.props.inspect()),
    `ui: the outlet {outlet.name} {versionText(outlet.version)} is already declared with another schema`
  )
  return version
end

-- Adds a prepared contribution, answering its record and the function that removes it.
function outlets.add(
  target: Outlets,
  owner: plugin.Owner,
  outlet: uiHost.Outlet<any>,
  version: uiHost.Version,
  bind: (uiHost.OutletMount) -> ()
): (records.Contribution, () -> ())
  assert(
    outlets.hold(target, outlet),
    `ui: the outlet {outlet.name} {versionText(outlet.version)} is already declared with another schema`
  )
  target.sequence += 1
  local record: records.Contribution = {
    outlet = outlet.name,
    owner = owner,
    contributor = plugin.ownerLabel(owner),
    version = table.freeze { major = version.major, minor = version.minor },
    bind = bind,
    sequence = target.sequence,
  }
  local list = target.contributions[outlet.name] or {}
  target.contributions[outlet.name] = list
  table.insert(list, record)
  for _, placement in target.placements do
    local node = placement.node
    if placement.declaration and placement.declaration.name == outlet.name and not node.dead then
      node.dirty = true
      node.panel.dirty = true
    end
  end
  return record,
    function(): ()
      local current = target.contributions[outlet.name]
      local index = current and table.find(current, record)
      if current and index then
        table.remove(current, index)
        if #current == 0 then
          target.contributions[outlet.name] = nil
        end
      end
      outlets.release(target, outlet)
    end
end

export type Inspected = {
  read contribution: records.Contribution,
  read placements: number,
}

-- Every live contribution, with the number of placements it renders in.
function outlets.inspect(target: Outlets): { Inspected }
  local list: { Inspected } = {}
  local names: { string } = {}
  for name in target.contributions do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in names do
    for _, contribution in target.contributions[name] do
      local count = 0
      for _, placement in target.placements do
        for _, entry in placement.mounts do
          if entry.contribution == contribution then
            count += 1
          end
        end
      end
      list[#list + 1] = { contribution = contribution, placements = count }
    end
  end
  return list
end

return outlets
