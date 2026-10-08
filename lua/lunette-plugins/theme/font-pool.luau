-- File faces belong to one provider activation; invocation holds can outlive its public cache.

local contract = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'

local fonts = {}

export type Hold = 'selection' | 'lease' | 'invocation'
export type Record = {
  spec: contract.FontSpec,
  font: Font,
  holds: { [Hold]: number },
  released: boolean,
}
export type Pool = {
  hold: (Pool, contract.FontSpec, Hold) -> Record,
  retain: (Pool, Record, Hold) -> (),
  drop: (Pool, Record, Hold) -> (),
  defer: (Pool, boolean) -> (),
  close: (Pool) -> (),
}

function fonts.new(): Pool
  local records: { [string]: Record } = {}
  local pending: { [Record]: boolean } = {}
  local open = true
  local deferred = false

  local function reclaim(record: Record): ()
    if record.released or record.holds.selection + record.holds.lease + record.holds.invocation ~= 0 then
      return
    end
    if deferred then
      pending[record] = true
      return
    end
    pending[record] = nil
    local key = descriptors.fontKey(record.spec)
    if records[key] == record then
      records[key] = nil
    end
    record.released = true
    if record.spec.kind == 'file' then
      record.font:release()
    end
  end

  local function reclaimAll(retired: { [Record]: boolean }): ()
    local failures: { string } = {}
    for record in retired do
      local ok, failure = pcall(reclaim, record)
      if not ok then
        failures[#failures + 1] = tostring(failure)
      end
    end
    if #failures > 0 then
      error('theme font cleanup: ' .. table.concat(failures, '; '), 0)
    end
  end

  return {
    hold = function(_self: Pool, spec: contract.FontSpec, kind: Hold): Record
      assert(open, 'theme font acquisition: the provider is inactive')
      local key = descriptors.fontKey(spec)
      local record: Record? = records[key]
      if record == nil then
        local face = if spec.kind == 'default'
          then lovr.graphics.getDefaultFont()
          else lovr.graphics.newFont(spec.file, spec.size, spec.spread)
        local counts: { [Hold]: number } = {}
        counts.selection, counts.lease, counts.invocation = 0, 0, 0
        local created: Record = {
          spec = spec,
          font = face,
          holds = counts,
          released = false,
        }
        records[key] = created
        record = created
      end
      assert(record ~= nil, 'theme font acquisition: no face was acquired')
      record.holds[kind] += 1
      pending[record] = nil
      return record
    end,
    retain = function(_self: Pool, record: Record, kind: Hold): ()
      assert(not record.released, 'theme font hold: the face is released')
      record.holds[kind] += 1
      pending[record] = nil
    end,
    drop = function(_self: Pool, record: Record, kind: Hold): ()
      assert(record.holds[kind] > 0, 'theme font hold: an unbalanced release')
      record.holds[kind] -= 1
      reclaim(record)
    end,
    defer = function(_self: Pool, value: boolean): ()
      deferred = value
      if not value then
        reclaimAll(table.clone(pending))
      end
    end,
    close = function(_self: Pool): ()
      if not open then
        return
      end
      open = false
      local retired: { [Record]: boolean } = {}
      for _, record in records do
        retired[record] = true
      end
      records = {}
      reclaimAll(retired)
    end,
  }
end

return fonts
