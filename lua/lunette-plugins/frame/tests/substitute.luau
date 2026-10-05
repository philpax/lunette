local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local inspection = require '@lunette-contracts/inspection'

local test = testing.suite()

test('a neutral frame substitute supplies batch observers and physical event batch IDs', function()
  local drive, service, providerContext
  local substitute = plugin.define {
    name = 'frame-substitute',
    provides = { frame = frame.capability },
    init = function(context, _config, publish)
      providerContext = context
      local current, id = nil, 0
      local lists = { onBatch = {}, onUpdate = {}, onDraw = {}, onKey = {}, onText = {}, onQuit = {} }
      service = {
        inspect = function()
          return inspection.snapshot({}, {})
        end,
      }
      for name, list in pairs(lists) do
        service[name] = function(_self, owner, handler)
          local entry = { owner = owner, run = handler.run, active = true }
          local effect = context:acquire(owner, function()
            list[#list + 1] = entry
            return function()
              entry.active = false
              table.remove(list, table.find(list, entry))
            end
          end)
          if name == 'onBatch' and current then
            handler.run(current)
          end
          return effect
        end
      end
      local function dispatch(name, value)
        for _, entry in ipairs(table.clone(lists[name])) do
          if entry.active and context:owns(entry.owner) and (name ~= 'onBatch' or current == value) then
            entry.run(value)
          end
        end
      end
      service.blockText = function(_self, batchId)
        if not context:active() or current == nil or current.id ~= batchId then
          return false
        end
        if not current.textBlocked then
          current = table.freeze { id = current.id, textBlocked = true }
          dispatch('onBatch', current)
        end
        return true
      end
      drive = function()
        id += 1
        current = table.freeze { id = id, textBlocked = false }
        dispatch('onBatch', current)
        dispatch('onUpdate', 0.016)
        dispatch('onKey', table.freeze { batch = current.id, key = 'a', scancode = 4, isRepeat = false })
        dispatch('onText', table.freeze { batch = current.id, text = 'a', code = 97 })
      end
      publish:provide(frame.capability, service)
    end,
  }
  local session = testing.start { { id = 'frame', definition = substitute } }
  local current, trace, oldOwner = nil, {}, nil
  local consumer = session:use(plugin.define {
    name = 'batch-substitute-consumer',
    requires = { frame = frame.capability },
    init = function(context)
      oldOwner = oldOwner or context
      local received = context:require(frame.capability)
      received:onBatch(context, {
        run = function(batch)
          current = batch.id
          trace[#trace + 1] = if batch.textBlocked then 'blocked' else 'batch'
        end,
      })
      received:onUpdate(context, {
        phase = 'input',
        run = function()
          trace[#trace + 1] = 'update'
        end,
      })
      received:onKey(context, {
        phase = 'delivery',
        run = function(event)
          expect.equal(event.batch, current, 'a substitute key carries its observed batch')
          trace[#trace + 1] = 'key'
        end,
      })
      received:onText(context, {
        phase = 'delivery',
        run = function(event)
          expect.equal(event.batch, current, 'a substitute text event carries its observed batch')
          trace[#trace + 1] = 'text'
        end,
      })
    end,
  })
  expect.equal(consumer:state(), 'active', 'a consumer accepts the substitute')
  drive()
  expect.equal(table.concat(trace, ' '), 'batch update key text', 'the contract does not require provider imports')
  table.clear(trace)
  consumer:disable()
  drive()
  expect.equal(#trace, 0, 'the substitute honors observer ownership')
  consumer:enable()
  expect.equal(table.concat(trace, ' '), 'batch', 'the substitute initializes a late observer')
  expect.falsy(providerContext:owns(oldOwner), 'the old owner generation is invalid')
  table.clear(trace)
  expect.truthy(service:blockText(current), 'the neutral substitute accepts current-batch invalidation')
  expect.truthy(service:blockText(current), 'repeated invalidation succeeds without changing metadata')
  expect.falsy(service:blockText(current - 1), 'a stale batch cannot block the current substitute batch')
  expect.equal(table.concat(trace, ' '), 'blocked', 'the substitute notifies one metadata replacement')
  consumer:disable()
  consumer:enable()
  expect.equal(table.concat(trace, ' '), 'blocked blocked', 'a recovered consumer immediately sees blocked state')
  session:close()
  expect.falsy(service:blockText(current), 'an ended substitute activation cannot mutate its retained batch')
end)

return test
