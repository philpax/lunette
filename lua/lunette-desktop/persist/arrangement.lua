-- Capturing panels into an arrangement and restoring an arrangement onto them.
--
-- The functions here read and write panels and tags through their services
-- and slot holds through a Slots record. They keep no state of their own.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local tagsContract = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'
local format = require '@lunette-desktop/persist/format'
local slots = require '@lunette-desktop/persist/slots'

local arrangement = {}

type Entry = format.Entry

-- The identity a panel is saved under, or nil.
function arrangement.sourceKey(held: slots.Slots, target: panelsContract.Panel): string?
  return held:key(target)
end

function arrangement.slotKey(kind: string, key: string, slot: number): string
  return kind .. '\0' .. key .. '\0' .. slot
end

function arrangement.slotsFor(file: format.File): { [string]: Entry }
  local available: { [string]: Entry } = {}
  for _, entry in ipairs(format.entries(file)) do
    available[arrangement.slotKey(entry.kind, entry.key, entry.slot)] = entry
  end
  return available
end

-- A window's properties from a file, for the slot the window holds or would
-- take. Records nothing.
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

-- The slot a panel is saved under. A window panel uses the slot its window
-- holds; a monitor panel counts the live monitor panels of its identity that
-- come before it.
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

function arrangement.capture(
  report: (string) -> (),
  held: slots.Slots,
  panels: panelsContract.Service,
  tags: tagsContract.Service
): format.File
  local entries: { Entry } = {}
  local counts: { [string]: number } = {}
  for _, target in ipairs(panels:all()) do
    if not target.dead then
      local key = arrangement.sourceKey(held, target)
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
        report('a ' .. target.kind .. ' panel has no identity, so it is not saved')
      end
    end
  end
  return format.newFile(entries)
end

-- Applies a saved entry to a panel. Memberships and the holds on the tags
-- they join are effects of the binding's context, so they end with it. Answers whether the entry was applied.
function arrangement.apply(
  report: (string) -> (),
  context: plugin.Context,
  tags: tagsContract.Service,
  target: panelsContract.Panel,
  entry: Entry
): boolean
  local placed = vocabulary.decodePose(entry.pose)
  if not placed then
    report("the pose saved for '" .. entry.key .. "' is not sixteen numbers")
    return false
  end
  target:setPose(placed)
  if entry.width or entry.height then
    target:setSize(entry.width, entry.height)
  end
  for _, name in ipairs(entry.tags) do
    local found = tags:hold(context, { name = name })
    found:add(context, target)
  end
  return true
end

-- Restores each live panel a saved entry matches. Answers the panels
-- restored and the entries nothing matched, which the caller reports: it
-- knows which it has reported already.
function arrangement.restore(
  report: (string) -> (),
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
      local key = arrangement.sourceKey(held, target)
      local slot = key and arrangement.panelSlot(held, counts, target, key)
      local entry = key and slot and available[arrangement.slotKey(target.kind, key, slot)]
      if entry and arrangement.apply(report, context, tags, target, entry) then
        restored[#restored + 1] = target
        matched[entry] = true
      end
    end
  end

  local stale: { Entry } = {}
  for _, entry in ipairs(format.entries(file)) do
    if not matched[entry] then
      stale[#stale + 1] = entry
    end
  end
  return restored, stale
end

-- Restores a monitor panel that appears after the binding, such as a monitor
-- that is plugged in or mirrored again. A window panel that appears takes its
-- slot instead: its saved properties reached it through the rules source.
function arrangement.arrived(
  report: (string) -> (),
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
  local key = arrangement.sourceKey(held, target)
  if not key then
    return
  end
  local slot = 1
  for _, other in ipairs(panels:all()) do
    if other ~= target and not other.dead and other.kind == 'monitor' and arrangement.sourceKey(held, other) == key then
      slot += 1
    end
  end
  local entry = arrangement.slotsFor(file)[arrangement.slotKey('monitor', key, slot)]
  if entry then
    arrangement.apply(report, context, tags, target, entry)
  end
end

return arrangement
