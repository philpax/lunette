-- Captures and restores panel arrangements through service contracts.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'
local format = require './format'
local slots = require './slots'

local arrangement = {}

type Entry = format.Entry

function arrangement.slotKey(kind: string, key: string, slot: number): string
  return kind .. '\0' .. key .. '\0' .. slot
end

function arrangement.slotsFor(file: format.File): { [string]: Entry }
  local available: { [string]: Entry } = {}
  for _, entry in ipairs(file.entries) do
    available[arrangement.slotKey(entry.kind, entry.key, entry.slot)] = entry
  end
  return available
end

-- Resolves saved window properties without assigning a slot.
function arrangement.answer(
  available: { [string]: Entry },
  held: slots.Slots,
  window: lunette.Window
): rulesContract.Properties?
  local identity = held:key { kind = 'window', source = window }
  local slot = identity and held:slotFor(window)
  if not identity or not slot then
    return nil
  end
  local entry = available[arrangement.slotKey('window', identity, slot)]
  if not entry then
    return nil
  end
  return { pose = entry.pose, width = entry.width, height = entry.height, tags = entry.tags }
end

-- The slot that identifies a panel's saved entry. Windows keep a held slot; monitors take their ordinal among the
-- live panels of the same identity, in service order, so two mirrors of one key get distinct entries. The arrangement
-- and the properties store both use this, so a save cannot put two mirrors on one slot.
function arrangement.slotOf(held: slots.Slots, panels: panelsContract.Service, target: panelsContract.Panel): number?
  if target.dead then
    return nil
  end
  local key = held:key(target)
  if not key then
    return nil
  end
  if target.kind == 'window' then
    return held:hold(target.source)
  end
  local slot = 0
  for _, other in ipairs(panels:all()) do
    if not other.dead and other.kind == 'monitor' and held:key(other) == key then
      slot += 1
      if other == target then
        return slot
      end
    end
  end
  return nil
end

function arrangement.capture(held: slots.Slots, panels: panelsContract.Service, tags: tagsContract.Service): format.File
  local entries: { Entry } = {}
  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = held:key(target)
      local slot = arrangement.slotOf(held, panels, target)
      if key and slot then
        local names: { string } = {}
        for _, existing in ipairs(tags:all()) do
          if existing:has(target) then
            names[#names + 1] = existing.name
          end
        end
        entries[#entries + 1] = {
          kind = target.kind,
          key = key,
          slot = slot,
          pose = vocabulary.encodePose(target.pose),
          width = target.width,
          height = target.height,
          tags = names,
        }
      else
        logging.report('a ' .. target.kind .. ' panel has no identity, so it is not saved', 'warn')
      end
    end
  end
  return { entries = entries }
end

-- The captured arrangement with every earlier entry that no live panel replaced, such as a monitor not mirrored yet
-- or an application that is closed, so a save does not forget what is absent.
function arrangement.merge(previous: format.File, captured: format.File): format.File
  local present = arrangement.slotsFor(captured)
  local entries = table.clone(captured.entries)
  for _, entry in ipairs(previous.entries) do
    if not present[arrangement.slotKey(entry.kind, entry.key, entry.slot)] then
      entries[#entries + 1] = entry
    end
  end
  return { entries = entries }
end

-- Applies saved pose, size, and tag membership. Tag holds belong to the binding context. The format refuses an entry
-- whose pose does not decode. The input lock, curve, and transform lock belong to the properties store.
function arrangement.apply(
  context: plugin.Context,
  tags: tagsContract.Service,
  target: panelsContract.Panel,
  entry: Entry
): ()
  target:setPose(assert(vocabulary.decodePose(entry.pose)))
  if entry.width or entry.height then
    if target.kind == 'monitor' and entry.width then
      target:setSize(entry.width, nil)
    else
      target:setSize(entry.width, entry.height)
    end
  end
  for _, name in ipairs(entry.tags) do
    local found = tags:hold(context, { name = name })
    found:add(context, target)
  end
end

-- Restores matching live panels and returns entries without a matching panel for caller-side reporting.
function arrangement.restore(
  held: slots.Slots,
  context: plugin.Context,
  panels: panelsContract.Service,
  tags: tagsContract.Service,
  file: format.File
): ({ panelsContract.Panel }, { Entry })
  local available = arrangement.slotsFor(file)
  local restored: { panelsContract.Panel } = {}
  local matched: { [Entry]: boolean } = {}

  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = held:key(target)
      local slot = arrangement.slotOf(held, panels, target)
      local entry = key and slot and available[arrangement.slotKey(target.kind, key, slot)]
      if entry then
        arrangement.apply(context, tags, target, entry)
        restored[#restored + 1] = target
        matched[entry] = true
      end
    end
  end

  local stale: { Entry } = {}
  for _, entry in ipairs(file.entries) do
    if not matched[entry] then
      stale[#stale + 1] = entry
    end
  end
  return restored, stale
end

-- Restores late monitor panels. Window panels receive saved properties through the rules source.
function arrangement.arrived(
  held: slots.Slots,
  context: plugin.Context,
  panels: panelsContract.Service,
  tags: tagsContract.Service,
  file: format.File,
  target: panelsContract.Panel
): ()
  if target.kind == 'window' then
    held:hold(target.source)
    return
  end
  local key = held:key(target)
  if not key then
    return
  end
  local slot = arrangement.slotOf(held, panels, target)
  local entry = slot and arrangement.slotsFor(file)[arrangement.slotKey('monitor', key, slot)]
  if entry then
    arrangement.apply(context, tags, target, entry)
  end
end

return arrangement
