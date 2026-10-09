-- A native target owns one optional outline attachment, including while joining is unavailable.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'
local frameStyle = require '@lunette-plugins/theme/frame-style'

local frame = {}

export type Record = {
  read owner: plugin.Owner,
  read eligible: () -> boolean,
  style: vocabulary.FrameStyle,
  live: boolean,
  effect: plugin.Effect?,
}

export type Target = {
  read dead: boolean,
  read hidden: boolean,
  read curve: number,
  read granted: boolean,
  read source: { read dead: boolean },
  read host: {
    read active: () -> boolean,
    read checkOwner: (plugin.Owner) -> (),
    read acquire: (plugin.Owner, () -> () -> ()) -> plugin.Effect,
  },
  frame: Record?,
}

function frame.joined(record: Record?): boolean
  return record ~= nil and record.live and record.eligible()
end

function frame.attach(target: Target, owner: plugin.Owner, style: vocabulary.FrameStyle): vocabulary.FrameAttachment
  local validated = frameStyle.validate(style)
  target.host.checkOwner(owner)
  if target.dead or target.source.dead or not target.host.active() then
    error('panels attachFrame: the target is dead', 2)
  end
  if target.frame and target.frame.live then
    error('panels attachFrame: the target already has a live attachment', 2)
  end
  local record: Record = {
    owner = owner,
    eligible = function(): boolean
      return target.host.active()
        and not target.dead
        and not target.source.dead
        and not target.hidden
        and target.curve == 0
        and not target.granted
    end,
    style = validated,
    live = true,
    effect = nil,
  }
  local effect = target.host.acquire(owner, function(): () -> ()
    target.frame = record
    return function(): ()
      record.live = false
      record.effect = nil
      if target.frame == record then
        target.frame = nil
      end
    end
  end)
  if record.live then
    record.effect = effect
  end
  local attachment: vocabulary.FrameAttachment = {
    update = function(_self: vocabulary.FrameAttachment, replacement: vocabulary.FrameStyle): ()
      if not record.live or target.dead or target.source.dead or not target.host.active() then
        error('panels frame update: the attachment or target is dead', 2)
      end
      record.style = frameStyle.validate(replacement)
    end,
    isJoined = function(_self: vocabulary.FrameAttachment): boolean
      return frame.joined(record)
    end,
    dispose = function(_self: vocabulary.FrameAttachment): ()
      if not record.live then
        return
      end
      target.frame = nil
      record.live = false
      local held = record.effect
      record.effect = nil
      if held then
        held:dispose()
      end
    end,
  }
  return table.freeze(attachment)
end

function frame.clear(target: Target): ()
  local record = target.frame
  target.frame = nil
  if not record then
    return
  end
  record.live = false
  local effect = record.effect
  record.effect = nil
  if effect then
    effect:dispose()
  end
end

return frame
