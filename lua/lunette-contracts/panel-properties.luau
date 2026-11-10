-- The properties every panel family persists, and the identity the properties store keys them by.
-- Pose, size, and tags are placement, which the arrangement owns; these values belong to the panel alone.

local panelProperties = {}

export type PanelProperties = {
  read curve: number,
  read curveAxis: number,
  read inputLocked: boolean,
  read transformLocked: boolean,
}

-- A window application id plus slot, a monitor key plus slot, or a toolkit panel name. Native slots match the
-- arrangement's held slots, so a save restores each panel's own properties.
export type PanelId =
  { read kind: 'window', read appId: string, read slot: number }
  | { read kind: 'monitor', read key: string, read slot: number }
  | { read kind: 'toolkit', read name: string }

-- What a panel family reads for its shared value. Native panels bend about the vertical only, so their axis is zero.
export type Fields = {
  read curve: number,
  read curveAxis: number,
  read inputLocked: boolean,
  read transformLocked: boolean,
}

function panelProperties.propertiesOf(fields: Fields): PanelProperties
  return {
    curve = fields.curve,
    curveAxis = fields.curveAxis,
    inputLocked = fields.inputLocked,
    transformLocked = fields.transformLocked,
  }
end

function panelProperties.equal(first: PanelProperties, second: PanelProperties): boolean
  return first.curve == second.curve
    and first.curveAxis == second.curveAxis
    and first.inputLocked == second.inputLocked
    and first.transformLocked == second.transformLocked
end

-- A segment survives a map key: the separators and the escape character are percent-encoded.
local function encodeSegment(text: string): string
  return (
    string.gsub(text, '[%%/:@#]', function(character: string): string
      return string.format('%%%02X', string.byte(character))
    end)
  )
end

local function decodeSegment(text: string): string?
  local position = string.find(text, '%%')
  while position do
    if not string.find(string.sub(text, position + 1, position + 2), '^%x%x$') then
      return nil
    end
    position = string.find(text, '%%', position + 3)
  end
  return (
    string.gsub(text, '%%(%x%x)', function(hex: string): string
      return string.char(tonumber(hex, 16) :: number)
    end)
  )
end

function panelProperties.encodeId(id: PanelId): string
  if id.kind == 'toolkit' then
    return 'toolkit/' .. encodeSegment(id.name)
  end
  local identifier = if id.kind == 'window' then id.appId else id.key
  return id.kind .. '/' .. encodeSegment(identifier) .. '/' .. id.slot
end

local function wholeSlot(text: string): number?
  local slot = tonumber(text)
  if type(slot) == 'number' and slot >= 1 and slot == math.floor(slot) and slot < math.huge then
    return slot
  end
  return nil
end

function panelProperties.decodeId(key: string): PanelId?
  local segments: { string } = {}
  for segment in string.gmatch(key, '[^/]+') do
    segments[#segments + 1] = segment
  end
  local kind = segments[1]
  if kind == 'toolkit' and #segments == 2 then
    local name = decodeSegment(segments[2])
    if name and name ~= '' then
      return { kind = 'toolkit', name = name }
    end
    return nil
  end
  if (kind == 'window' or kind == 'monitor') and #segments == 3 then
    local identifier = decodeSegment(segments[2])
    local slot = wholeSlot(segments[3])
    if identifier and identifier ~= '' and slot then
      if kind == 'window' then
        return { kind = 'window', appId = identifier, slot = slot }
      end
      return { kind = 'monitor', key = identifier, slot = slot }
    end
  end
  return nil
end

return panelProperties
