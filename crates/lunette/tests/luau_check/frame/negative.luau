local frame = require '@lunette-contracts/frame'

local function misuse(
  service: frame.Service,
  owner: frame.Owner,
  batch: frame.Batch,
  key: frame.KeyEvent,
  text: frame.TextEvent
)
  service:blockText 'one' -- reject.
  service:blockText(batch) -- reject.
  service.blockText = function(_self: frame.Service, _batchId: number): boolean -- reject.
    return true
  end
  local wrongBlockResult: string = service:blockText(batch.id) -- reject.
  batch.id = 2 -- reject.
  key.batch = 2 -- reject.
  text.batch = 2 -- reject.
  service:onBatch(owner, { run = function(_id: number): () end }) -- reject.
  service:onBatch(owner, { run = false }) -- reject.
  service:onBatch({}, { run = function(_batch: frame.Batch): () end }) -- reject.
  local missingKeyBatch: frame.KeyEvent = { key = 'a', scancode = 4, isRepeat = false } -- reject.
  local missingTextBatch: frame.TextEvent = { text = 'a', code = 97 } -- reject.
  local wrongBatch: frame.Batch = { id = 'one', textBlocked = false } -- reject.
  batch.textBlocked = true -- reject.
  local wrongTextBlocked: frame.Batch = { id = 1, textBlocked = 1 } -- reject.
  local missingTextBlocked: frame.Batch = { id = 1 } -- reject.
  return {
    wrongBlockResult = wrongBlockResult,
    key = missingKeyBatch,
    text = missingTextBatch,
    batch = wrongBatch,
    wrongTextBlocked = wrongTextBlocked,
    missingTextBlocked = missingTextBlocked,
  }
end

local function snapshotMisuse(key: frame.KeyEvent)
  key.modifiers = nil -- reject.
  if key.modifiers then
    key.modifiers.numLock = false -- reject.
    key.modifiers.shift = false -- reject.
  end
  local wrong: frame.KeyEvent = {
    batch = 1,
    key = 'kp1',
    scancode = 79,
    isRepeat = false,
    modifiers = { shift = 1, control = false, alt = false, super = false, capsLock = false, numLock = true }, -- reject.
  }
  local missing: frame.KeyEvent = {
    batch = 1,
    key = 'kp1',
    scancode = 79,
    isRepeat = false,
    modifiers = { shift = false }, -- reject.
  }
  return { wrong, missing }
end

return { misuse, snapshotMisuse }
