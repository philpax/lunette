-- Captures and restores panel arrangements through service contracts.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'
local format = require '@lunette-plugins/arrangement/format'
local slots = require '@lunette-plugins/arrangement/slots'

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

-- Window panels use held slots; monitor panels use their order among live panels of the same identity.
function arrangement.panelSlot(
  held: slots.Slots,
  counts: { [string]: number },
  target: panelsContract.Panel,
  key: string
): number?
  if target.kind == 'window' then
    return held:hold(target.source)
  end
  local counted = target.kind .. '\0' .. key
  local slot = (counts[counted] or 0) + 1
  counts[counted] = slot
  return slot
end

function arrangement.capture(held: slots.Slots, panels: panelsContract.Service, tags: tagsContract.Service): format.File
  local entries: { Entry } = {}
  local counts: { [string]: number } = {}
  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = held:key(target)
      local slot = key and arrangement.panelSlot(held, counts, target, key)
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

-- Applies saved pose, size, and tag membership. Tag holds belong to the binding context. The format refuses an
-- entry whose pose does not decode.
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
  local counts: { [string]: number } = {}

  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = held:key(target)
      local slot = key and arrangement.panelSlot(held, counts, target, key)
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
  local slot = 1
  for _, other in ipairs(panels:all()) do
    if other ~= target and not other.dead and other.kind == 'monitor' and held:key(other) == key then
      slot += 1
    end
  end
  local entry = arrangement.slotsFor(file)[arrangement.slotKey('monitor', key, slot)]
  if entry then
    arrangement.apply(context, tags, target, entry)
  end
end

return arrangement
