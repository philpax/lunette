-- Delivers physical keys and committed text through the focused route after binding handlers.
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local keys = require '@lunette-contracts/keys'

local function heldModifiers(): { string }
  return keys.heldModifiers { isDown = lovr.system.isKeyDown, shift = true }
end

return plugin.consumer<<{}, {}>>({
  name = 'desktop/input',
  requires = { focus = focus.capability, frame = frame.capability },
  init = function(context: plugin.Context, _settings: {}): ()
    local frameService: frame.Service = context:require(frame.capability)
    local service: focus.Service = context:require(focus.capability)
    local source = service:newSource(context, { mode = 'physical' })
    local currentBatch: number? = nil
    frameService:onBatch(context, {
      run = function(batch: frame.Batch): ()
        currentBatch = batch.id
        source:beginBatch(batch.id)
        if batch.textBlocked then
          source:reset()
        end
      end,
    })
    frameService:onKey(context, {
      phase = 'delivery',
      run = function(event: frame.KeyEvent): boolean?
        local code = keys.FROM_LOVR[event.key]
        if code == nil then
          return nil
        end
        local modifiers = if event.modifiers
          then keys.physicalModifierNames(event.modifiers, lovr.system.isKeyDown)
          else heldModifiers()
        local selected = service:focused() ~= nil
        local result = source:key {
          code = code,
          modifiers = modifiers,
          physicalModifiers = event.modifiers,
          isRepeat = event.isRepeat,
          batch = event.batch,
        }
        if keys.commandChord(modifiers) or result.kind ~= 'unhandled' then
          frameService:blockText(event.batch)
        end
        return result.kind ~= 'unhandled' or selected
      end,
    })
    frameService:onText(context, {
      phase = 'delivery',
      run = function(event: frame.TextEvent): boolean?
        if keys.commandChord(heldModifiers()) then
          frameService:blockText(event.batch)
          return true
        end
        local selected = service:focused() ~= nil
        local result = source:text(event.text, event.batch)
        if result.kind == 'failed' or result.kind == 'refused' then
          frameService:blockText(event.batch)
        end
        return result.kind ~= 'unhandled' or selected
      end,
    })
    context:effect(function(): () -> ()
      return function(): ()
        -- Replacing the physical source cannot renew the pending batch with a different route snapshot.
        if currentBatch ~= nil then
          frameService:blockText(currentBatch)
        end
      end
    end)
  end,
}).definition
