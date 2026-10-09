-- Delivers physical keys and committed text through the focused route after binding handlers.
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local keys = require '@lunette-contracts/keys'

return plugin.consumer<<{}, {}>>({
  name = 'desktop/input',
  requires = { focus.capability, frame.capability },
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
      run = function(event: frame.HostKeyEvent): boolean?
        local code = event.code
        if code == nil then
          return nil
        end
        local selected = service:focused() ~= nil
        local result = source:key {
          code = code,
          modifiers = event.modifiers,
          physicalModifiers = event.physicalModifiers,
          isRepeat = event.isRepeat,
          batch = event.batch,
        }
        if keys.commandChord(event.modifiers) or result.kind ~= 'unhandled' then
          frameService:blockText(event.batch)
        end
        return result.kind ~= 'unhandled' or selected
      end,
    })
    frameService:onText(context, {
      phase = 'delivery',
      run = function(event: frame.HostTextEvent): boolean?
        if keys.commandChord(event.modifiers) then
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
