local testing = require '@testing'
local expect = testing.expect
local contract = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local test = testing.suite()

local function count(snapshot, kind)
  local total = 0
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind then
      total += 1
    end
  end
  return total
end

local function countOwned(snapshot, kind, owner)
  local total = 0
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind and entry.owner == owner then
      total += 1
    end
  end
  return total
end

local function registration(snapshot, kind)
  for _, entry in ipairs(snapshot.registrations) do
    if entry.kind == kind then
      return entry
    end
  end
  error('missing ' .. kind .. ' registration')
end

local function expectFrozen(snapshot)
  expect.equal(table.isfrozen(snapshot), true, 'the frozen snapshot')
  expect.equal(table.isfrozen(snapshot.registrations), true, 'the frozen registration list')
  expect.equal(table.isfrozen(snapshot.state), true, 'the frozen state')
  expect.equal(table.isfrozen(snapshot.unobservable), true, 'the frozen unavailable facts')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(table.isfrozen(entry), true, 'the frozen registration')
    expect.equal(table.isfrozen(entry.details), true, 'the frozen registration details')
  end
end

test('inspection separates adoption from provider-owned placements without enumeration or filtering', function()
  local native = testing.native()
  local window = native.newWindow(25)
  native.events.windows = { window }
  local session = testing.start {
    'theme',
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = { rendering = 'layer' } },
    'tags',
    'rules',
    'placement',
    'adoption',
  }
  local observed = session:observe(contract.capability)
  local service, owner = observed.service, observed.context
  local installed = service:install(owner)
  local filterCalls, placedCalls = 0, 0
  local started = service:start(owner, {
    filter = function()
      filterCalls += 1
      return true
    end,
    onPlaced = function()
      placedCalls += 1
    end,
  })
  local placementObserved = session:observe(placementContract.capability)
  local panelsObserved = session:observe(panelsContract.capability)
  local placementService, panelsService = placementObserved.service, panelsObserved.service
  local claim = native.events.claims[1]
  expect.equal(native.events.enumerations, 1, 'the initial enumeration')
  expect.equal(filterCalls, 1, 'the initial filter call')
  expect.equal(placedCalls, 1, 'the initial placement callback')
  expect.equal(count(placementService:inspect(), 'placement'), 1, 'the adopted placement')
  expect.equal(count(panelsService:inspect(), 'panel'), 1, 'the adopted panel')

  local enumerationsBeforeInspect, filtersBeforeInspect = native.events.enumerations, filterCalls
  local snapshot = service:inspect()
  local placements = placementService:inspect()
  local panelSnapshot = panelsService:inspect()
  expect.equal(native.events.enumerations, enumerationsBeforeInspect, 'inspection does not enumerate windows')
  expect.equal(filterCalls, filtersBeforeInspect, 'inspection does not call the filter')
  expect.equal(placedCalls, 1, 'inspection does not call the placement callback')
  expect.equal(#snapshot.registrations, 3, 'the installation, producer, and adopted window')
  expect.equal(count(snapshot, 'poseSource'), 1, 'the caller-owned pose installation')
  expect.equal(count(snapshot, 'producer'), 1, 'the caller-owned producer')
  expect.equal(count(snapshot, 'adoption'), 1, 'the caller-owned adopted window')
  for _, entry in ipairs(snapshot.registrations) do
    expect.equal(entry.owner, owner, 'the caller owns adoption releases')
  end
  expect.equal(registration(snapshot, 'adoption').details.sourceId, window.id, 'the adopted window ID')
  expect.equal(#placements.registrations, 1, 'the separate placement registration')
  local placementEntry = registration(placements, 'placement')
  expect.equal(placementEntry.details.sourceId, window.id, 'the placement window ID')
  expect.equal(placementEntry.owner == owner, false, 'the placement has a provider-owned release')
  expect.equal(count(panelSnapshot, 'panel'), 1, 'the separate panel registration')
  expect.equal(count(panelSnapshot, 'listener'), 2, 'the nested removal listeners')
  local panelEntry = registration(panelSnapshot, 'panel')
  expect.equal(panelEntry.details.sourceId, window.id, 'the panel window ID')
  expect.equal(panelEntry.owner == placementEntry.owner, false, 'the panel has a separate provider owner')
  expect.equal(panelEntry.owner == owner, false, 'the caller does not own the panel resource')
  expect.equal(countOwned(panelSnapshot, 'listener', placementEntry.owner), 1, 'the adoption removal listener')
  expect.equal(countOwned(panelSnapshot, 'listener', panelEntry.owner), 1, 'the placement removal listener')
  expect.equal(placementEntry.owner == owner, false, 'the adoption provider owns the placement release')

  started:dispose()
  local afterStart = service:inspect()
  expect.equal(#afterStart.registrations, 1, 'disposing the caller producer releases its adoption')
  expect.equal(count(afterStart, 'producer'), 0, 'the released producer')
  expect.equal(count(afterStart, 'adoption'), 0, 'the released adopted window')
  expect.equal(count(placementService:inspect(), 'placement'), 0, 'the released nested placement')
  expect.equal(#panelsService:inspect().registrations, 0, 'the released panel and listener')
  expect.equal(claim.dead, true, 'releasing the caller-owned adoption releases its nested claim')
  expect.equal(window.dead, false, 'adoption disposal leaves the native window open')
  expect.equal(#snapshot.registrations, 3, 'the retained snapshot after disposal')
  expect.equal(count(placements, 'placement'), 1, 'the retained placement snapshot after disposal')
  expectFrozen(snapshot)
  expectFrozen(placements)
  expectFrozen(panelSnapshot)
  expect.raises(function()
    registration(snapshot, 'adoption').details.sourceId = 99
  end, 'readonly', 'the retained adoption metadata stays frozen')

  installed:dispose()
  expect.equal(#service:inspect().registrations, 0, 'the released installation')
  session:close()
end)

return test
