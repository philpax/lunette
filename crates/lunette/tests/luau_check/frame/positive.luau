local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local inspection = require '@lunette-contracts/inspection'
local keys = require '@lunette-contracts/keys'

local function build(context: plugin.Context): frame.Service
  local current: frame.Batch = table.freeze { id = 1, textBlocked = false }
  local keyCode: KeyCode = 'a'
  local input: frame.UpdatePhase = 'input'
  local scene: frame.UpdatePhase = 'scene'
  local delivery: frame.InputPhase = 'delivery'
  local key: frame.KeyEvent = table.freeze { batch = current.id, key = keyCode, scancode = 4, isRepeat = false }
  local flags: keys.PhysicalModifiers =
    table.freeze { shift = false, control = false, alt = false, super = false, capsLock = false, numLock = true }
  local keypad: frame.KeyEvent = { batch = current.id, key = 'kp1', scancode = 79, isRepeat = false, modifiers = flags }
  local snapshot: keys.PhysicalModifiers? = keypad.modifiers
  assert(snapshot == nil or snapshot.numLock)
  local text: frame.TextEvent = table.freeze { batch = current.id, text = 'a', code = 97 }
  local batchHandler: frame.BatchHandler = table.freeze {
    run = function(batch: frame.Batch): ()
      local id: number = batch.id
      local textBlocked: boolean = batch.textBlocked
      assert(id == current.id and textBlocked == current.textBlocked)
    end,
  }
  local handlers: { frame.BatchHandler } = {}
  local service: frame.Service = {
    inspect = function(_self: frame.Service): inspection.Snapshot
      return inspection.snapshot({}, {})
    end,
    blockText = function(_self: frame.Service, batchId: number): boolean
      if not context:active() or current.id ~= batchId then
        return false
      end
      if not current.textBlocked then
        local blocked: frame.Batch = table.freeze { id = current.id, textBlocked = true }
        current = blocked
        for _, handler in ipairs(table.clone(handlers)) do
          if current == blocked then
            handler.run(blocked)
          end
        end
      end
      return true
    end,
    onBatch = function(_self: frame.Service, owner: frame.Owner, handler: frame.BatchHandler): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        handlers[#handlers + 1] = handler
        handler.run(current)
        return function(): ()
          local index = table.find(handlers, handler)
          if index then
            table.remove(handlers, index)
          end
        end
      end)
    end,
    onUpdate = function(_self: frame.Service, owner: frame.Owner, _handler: frame.UpdateHandler): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        return function(): () end
      end)
    end,
    onDraw = function(_self: frame.Service, owner: frame.Owner, _handler: frame.DrawHandler): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        return function(): () end
      end)
    end,
    onKey = function(_self: frame.Service, owner: frame.Owner, handler: frame.KeyHandler): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        handler.run(key)
        return function(): () end
      end)
    end,
    onText = function(_self: frame.Service, owner: frame.Owner, handler: frame.TextHandler): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        handler.run(text)
        return function(): () end
      end)
    end,
    onQuit = function(_self: frame.Service, owner: frame.Owner, _handler: frame.QuitHandler): plugin.Effect
      return context:acquire(owner, function(): () -> ()
        return function(): () end
      end)
    end,
  }
  service:onBatch(context, batchHandler)
  local accepted: boolean = service:blockText(current.id)
  assert(accepted)
  service:onUpdate(context, table.freeze { phase = input, run = function(_dt: number): () end })
  service:onDraw(context, table.freeze { phase = scene, run = function(_pass: Pass): () end })
  service:onKey(
    context,
    table.freeze {
      phase = delivery,
      run = function(event: frame.KeyEvent): boolean?
        local batch: number = event.batch
        local code: KeyCode = event.key
        return batch == current.id and code == key.key
      end,
    }
  )
  service:onText(
    context,
    table.freeze {
      run = function(event: frame.TextEvent): boolean?
        local batch: number = event.batch
        return batch == current.id and event.text == text.text
      end,
    }
  )
  service:onQuit(context, table.freeze { run = function(): () end })
  return service
end

return plugin.define {
  name = 'neutral-frame-substitute',
  provides = { frame = frame.capability },
  init = function(context: plugin.Context, _config: {}, publish: plugin.Publisher): ()
    publish:provide(frame.capability, build(context))
  end,
}
