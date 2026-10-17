-- Outlet instances. Each placement of an outlet is an outlet node with a mount point for every compatible
-- contribution, in the outlet's order; a contribution's mount point renders in the panel's commit, and what it
-- submits becomes the content of a wrapper node among the outlet node's children.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'
local outletKinds = require './outlet-kinds'
local outlets = require './outlets'

local placements = {}

local versionText = outlets.versionText

-- The raw props of a placement that has not validated any yet.
local UNSET = table.freeze {}

local function invalidate(placement: records.Placement): ()
  local node = placement.node
  if not node.dead then
    node.dirty = true
    node.panel.dirty = true
  end
end

local function label(placement: records.Placement, contribution: records.Contribution): string
  return `ui: outlet '{contribution.outlet}' contribution from {contribution.contributor}`
    .. ` in panel '{placement.node.panel.name}'`
end

local function unmount(env: records.Environment, placement: records.Placement, entry: records.ContributionMount): ()
  if entry.dead then
    return
  end
  entry.dead = true
  entry.scheduled = false
  local adapter = entry.adapter
  if adapter and adapter.unmount then
    local finish = adapter.unmount
    env.protect(`{label(placement, entry.contribution)} unmount`, function(): ()
      finish()
    end)
  end
end

-- Ends a removed contribution's instances, so their effects clean up with its owner; their nodes go at the next
-- commit.
function placements.ended(target: outlets.Outlets, env: records.Environment, record: records.Contribution): ()
  for _, placement in table.clone(target.placements) do
    for _, entry in table.clone(placement.mounts) do
      if entry.contribution == record then
        unmount(env, placement, entry)
        table.remove(placement.mounts, assert(table.find(placement.mounts, entry)))
        invalidate(placement)
      end
    end
  end
end

local function newMount(
  env: records.Environment,
  placement: records.Placement,
  contribution: records.Contribution,
  key: string
): records.ContributionMount
  local entry: records.ContributionMount = {
    contribution = contribution,
    handle = nil :: any,
    adapter = nil,
    scheduled = false,
    committed = false,
    rendering = false,
    dead = false,
    element = nil,
    wrapped = nil,
    wrapper = nil,
    key = key,
  }
  local handle = {
    bind = function(_self: uiHost.Mount, adapter: uiHost.Adapter): ()
      assert(
        type(adapter) == 'table' and type(adapter.render) == 'function',
        'ui: a mount adapter has a render function'
      )
      if not entry.dead then
        entry.adapter = adapter
        entry.scheduled = true
      end
    end,
    schedule = function(_self: uiHost.Mount): ()
      if not entry.dead then
        entry.scheduled = true
      end
    end,
    submit = function(_self: uiHost.Mount, element: uiHost.Element?): ()
      assert(entry.rendering, 'ui: a mount point accepts elements only while the host renders it')
      if element ~= nil then
        assert(type(element) == 'table' and type(element.kind) == 'string', 'ui: a mount point takes an element')
      end
      if element ~= entry.element then
        entry.element = element
        invalidate(placement)
      end
    end,
    committed = function(_self: uiHost.Mount): boolean
      return entry.committed
    end,
    props = function(_self: uiHost.Mount): uiHost.Props
      return placement.props
    end,
  }
  entry.handle = handle :: any
  env.protect(`{label(placement, contribution)} bind`, function(): ()
    contribution.bind(entry.handle)
  end)
  return entry
end

-- The live contributions compatible with the placement, in the outlet's order. An ordering function that raises is
-- reported against the placing owner, and the contributors' names order them instead.
local function ordered(
  target: outlets.Outlets,
  env: records.Environment,
  placement: records.Placement,
  outlet: uiHost.Outlet<any>
): { records.Contribution }
  local list: { records.Contribution } = {}
  for _, contribution in target.contributions[outlet.name] or {} do
    if outlets.compatible(contribution.version, outlet.version) then
      list[#list + 1] = contribution
    elseif not placement.reported[contribution] then
      placement.reported[contribution] = true
      env.protect(label(placement, contribution), function(): ()
        error(
          `the contribution is built against version {versionText(contribution.version)}, and the outlet is `
            .. `version {versionText(outlet.version)}`,
          0
        )
      end)
    end
  end
  local function byName(first: records.Contribution, second: records.Contribution): boolean
    if first.contributor ~= second.contributor then
      return first.contributor < second.contributor
    end
    return first.sequence < second.sequence
  end
  local order = outlet.order
  if order then
    local sorted = table.clone(list)
    local ok = env.protect(`ui: outlet '{outlet.name}' order`, function(): ()
      table.sort(sorted, function(first: records.Contribution, second: records.Contribution): boolean
        if first.contributor == second.contributor then
          return first.sequence < second.sequence
        end
        return order({ contributor = first.contributor }, { contributor = second.contributor }) == true
      end)
    end)
    if ok then
      return sorted
    end
  end
  table.sort(list, byName)
  return list
end

local function wrap(
  placement: records.Placement,
  outlet: uiHost.Outlet<any>,
  entry: records.ContributionMount,
  content: uiHost.Element
): uiHost.Element
  local contribution = entry.contribution
  if outlet.attributed then
    return uiHost.element(outletKinds.FRAME, {
      key = entry.key,
      owner = contribution.owner,
      maxHeight = placement.node.props.maxHeight,
      uiHost.element(outletKinds.LABEL, { key = 'attribution', text = contribution.contributor }),
      uiHost.element(outletKinds.BODY, { key = 'body', content }),
    })
  end
  return uiHost.element(outletKinds.SLOT, { key = entry.key, owner = contribution.owner, content })
end

local function placementOf(target: outlets.Outlets, node: records.Node): records.Placement
  local existing = node.placement
  if existing then
    return existing
  end
  local placement: records.Placement = {
    node = node,
    declaration = nil,
    conflicting = false,
    raw = UNSET,
    props = table.freeze {} :: uiHost.Props,
    mounts = {},
    reported = {},
  }
  node.placement = placement
  table.insert(target.placements, placement)
  table.insert(node.panel.placements, placement)
  return placement
end

local function unmountAll(env: records.Environment, placement: records.Placement): ()
  for _, entry in placement.mounts do
    unmount(env, placement, entry)
  end
  table.clear(placement.mounts)
end

-- Takes up the declaration an outlet node names, reporting against the placing owner a value that is not one or a
-- schema that conflicts with a live declaration.
local function declare(target: outlets.Outlets, env: records.Environment, placement: records.Placement): ()
  local given = placement.node.props.outlet
  if given == placement.declaration then
    return
  end
  if placement.declaration and not placement.conflicting then
    outlets.release(target, placement.declaration)
  end
  unmountAll(env, placement)
  placement.declaration, placement.conflicting, placement.raw = nil, false, UNSET
  local panelName = placement.node.panel.name
  env.protect(`ui: outlet in panel '{panelName}'`, function(): ()
    local outlet = outlets.check(given)
    placement.declaration = outlet
    if not outlets.hold(target, outlet) then
      placement.conflicting = true
      error(`the outlet {outlet.name} {versionText(outlet.version)} is already declared with another schema`, 0)
    end
  end)
end

-- Props compare field by field, so a placement that renders again with equal props does not render its
-- contributions again.
local function shallowEqual(first: unknown, second: unknown): boolean
  if first == second then
    return true
  end
  if type(first) ~= 'table' or type(second) ~= 'table' then
    return false
  end
  local left, right = first :: { [unknown]: unknown }, second :: { [unknown]: unknown }
  for key, value in left do
    if right[key] ~= value then
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

-- Validates the placement's props against the outlet's schema and schedules every contribution when they change.
-- Props that do not fit are reported against the placing owner, and the contributions keep the last that did.
local function update(env: records.Environment, placement: records.Placement, outlet: uiHost.Outlet<any>): ()
  local raw = placement.node.props.props
  if placement.raw ~= UNSET and shallowEqual(raw, placement.raw) then
    return
  end
  placement.raw = raw
  env.protect(`ui: outlet '{outlet.name}' props in panel '{placement.node.panel.name}'`, function(): ()
    placement.props = outlet.props.parse(if raw == nil then {} else raw, outlet.name)
    for _, entry in placement.mounts do
      entry.scheduled = entry.adapter ~= nil and not entry.dead
    end
  end)
end

-- The children of an outlet node: a mount point for each compatible contribution, made or ended to match the live
-- contributions, and a wrapper around what each last submitted.
function placements.children(
  target: outlets.Outlets,
  env: records.Environment,
  node: records.Node
): ({ uiHost.Element }, { string })
  local placement = placementOf(target, node)
  declare(target, env, placement)
  local outlet = placement.declaration
  if outlet == nil or placement.conflicting then
    return {}, {}
  end
  update(env, placement, outlet)
  local live = ordered(target, env, placement, outlet)
  local previous: { [records.Contribution]: records.ContributionMount } = {}
  for _, entry in placement.mounts do
    previous[entry.contribution] = entry
  end
  local mounts: { records.ContributionMount } = {}
  local counts: { [string]: number } = {}
  for _, contribution in live do
    local count = (counts[contribution.contributor] or 0) + 1
    counts[contribution.contributor] = count
    local key = uiHost.keyOf(contribution.contributor) .. (if count > 1 then `.{count}` else '')
    local entry = previous[contribution]
    if entry then
      previous[contribution] = nil
      if entry.key ~= key then
        entry.key, entry.wrapper = key, nil
      end
    else
      entry = newMount(env, placement, contribution, key)
    end
    mounts[#mounts + 1] = assert(entry)
  end
  for _, stale in previous do
    unmount(env, placement, stale)
  end
  placement.mounts = mounts
  local elements: { uiHost.Element } = {}
  local slots: { string } = {}
  for _, entry in mounts do
    local content = entry.element
    if content then
      if entry.wrapper == nil or entry.wrapped ~= content or entry.wrapper.props.maxHeight ~= node.props.maxHeight then
        entry.wrapper = wrap(placement, outlet, entry, content)
        entry.wrapped = content
      end
      local wrapper = assert(entry.wrapper)
      elements[#elements + 1] = wrapper
      slots[#slots + 1] = entry.key
    end
  end
  return elements, slots
end

-- Renders the contribution mount points of the panel's placements that have scheduled work, answering whether any
-- rendered.
function placements.render(env: records.Environment, panel: records.Panel): boolean
  local rendered = false
  for _, placement in table.clone(panel.placements) do
    for _, entry in table.clone(placement.mounts) do
      local adapter = entry.adapter
      if entry.scheduled and adapter and not entry.dead and not placement.node.dead then
        entry.scheduled = false
        entry.rendering = true
        env.protect(`{label(placement, entry.contribution)} render`, function(): ()
          adapter.render()
        end)
        entry.rendering = false
        rendered = true
      end
    end
  end
  return rendered
end

-- Whether a contribution mount point of the panel has work scheduled.
function placements.pending(panel: records.Panel): boolean
  for _, placement in panel.placements do
    for _, entry in placement.mounts do
      if entry.scheduled and entry.adapter and not entry.dead then
        return true
      end
    end
  end
  return false
end

-- Marks every bound contribution mount point of the panel as committed.
function placements.committed(panel: records.Panel): ()
  for _, placement in panel.placements do
    for _, entry in placement.mounts do
      entry.committed = entry.adapter ~= nil
    end
  end
end

-- Ends the instance an outlet node held when the node is removed.
function placements.removed(target: outlets.Outlets, env: records.Environment, node: records.Node): ()
  local placement = node.placement
  if not placement then
    return
  end
  node.placement = nil
  unmountAll(env, placement)
  if placement.declaration and not placement.conflicting then
    outlets.release(target, placement.declaration)
  end
  local index = table.find(target.placements, placement)
  if index then
    table.remove(target.placements, index)
  end
  local panelIndex = table.find(node.panel.placements, placement)
  if panelIndex then
    table.remove(node.panel.placements, panelIndex)
  end
end

-- The owner of the subtree a node is in: the contributing owner inside a contribution, and otherwise the panel's.
function placements.ownerOf(node: records.Node): plugin.Owner
  local current: records.Node? = node
  while current do
    local name = current.kind.name
    if (name == outletKinds.FRAME or name == outletKinds.SLOT) and current.props.owner then
      return current.props.owner :: plugin.Owner
    end
    current = current.parent
  end
  return node.panel.owner
end

return placements
