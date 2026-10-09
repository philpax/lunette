-- Boots the real physical input path and records only its unmanaged native boundary.
local testing = require '@testing'
local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local expect = testing.expect

local physical = {}
local fixtures = {}
local strokes = {
  q = { keycode = 16, modifiers = {} },
  Q = { keycode = 16, modifiers = { 'shift' } },
  ['1'] = { keycode = 2, modifiers = {} },
  ['.'] = { keycode = 52, modifiers = {} },
  ['€'] = { keycode = 18, modifiers = { 'mod5' } },
  ['é'] = { keycode = 40, modifiers = {} },
  ['🙂'] = { keycode = 57, modifiers = { 'mod5', 'shift' } },
}
local Fixture = {}
Fixture.__index = Fixture

function physical.boot(domain)
  local session = testing.boot { 'frame', 'focus', 'desktop/input' }
  local observed = session:observe(focus.capability)
  local batches = session:observe(frame.capability)
  local fixture = setmetatable({
    session = session,
    native = session.native,
    focus = observed.service,
    owner = observed.context,
    frame = batches.service,
    frameOwner = batches.context,
    log = {},
    hooks = {},
    batch = nil,
  }, Fixture)
  fixtures[#fixtures + 1] = fixture
  fixture.seat = observed.context:resource(observed.context, function()
    local seat = lunette.newSeat 'physical-input-fixture'
    return seat, function()
      seat:destroy()
    end
  end)
  fixture.seat.strokeFor = function(_self, value)
    fixture:record('resolve:' .. value)
    local stroke = strokes[value]
    if stroke == nil then
      return nil
    end
    return { keycode = stroke.keycode, modifiers = table.clone(stroke.modifiers) }
  end
  fixture.sink = { dead = false, domain = domain or 'window', id = 701 }
  fixture.sink.modifiers = function(_self, modifiers, seat)
    expect.equal(seat, fixture.seat, 'the original native seat')
    fixture:record('mods:' .. table.concat(modifiers, '+'))
    return true
  end
  fixture.sink.key = function(_self, code, down, seat)
    expect.equal(seat, fixture.seat, 'the original native seat')
    fixture:record('key:' .. code .. ':' .. (if down then 'down' else 'up'))
    return if fixture.hooks.key then fixture.hooks.key(code, down) else true
  end
  fixture.sink.typeText = function(_self, text, seat)
    expect.equal(seat, fixture.seat, 'the original host seat')
    fixture:record('native-text:' .. text)
    return if fixture.hooks.text then fixture.hooks.text(text) else true
  end
  fixture.nativeTarget = fixture.focus:register(fixture.owner, {
    kind = 'native',
    seat = fixture.seat,
    sink = fixture.sink,
  })
  fixture.frame:onBatch(fixture.frameOwner, {
    run = function(batch)
      fixture.batch = batch.id
      fixture.textBlocked = batch.textBlocked
    end,
  })
  return fixture
end

function physical.suite()
  local suite = testing.suite()
  return setmetatable({}, {
    __call = function(_self, name, run)
      suite(name, function()
        local ok, message = pcall(run)
        for _, fixture in ipairs(fixtures) do
          if not fixture.closed then
            local cleaned, failure = pcall(function()
              fixture:close()
            end)
            if ok and not cleaned then
              ok, message = false, failure
            end
          end
        end
        table.clear(fixtures)
        if not ok then
          error(message, 0)
        end
      end)
    end,
    __index = function(_self, key)
      if key == 'result' then
        return suite
      end
      return nil
    end,
  })
end

function Fixture:record(value)
  self.log[#self.log + 1] = value
end

function Fixture:trace()
  return table.concat(self.log, '|')
end

function Fixture:clear()
  table.clear(self.log)
end

function Fixture:held(...)
  table.clear(self.native.events.held)
  for _, key in ipairs { ... } do
    self.native.events.held[key] = true
  end
end

function physical.modifiers(fields)
  local result = { shift = false, control = false, alt = false, super = false, capsLock = false, numLock = false }
  for name, value in fields or {} do
    result[name] = value
  end
  return result
end

function Fixture:pair(key, text, isRepeat, modifiers)
  lovr.keypressed(key, 987654, isRepeat == true, modifiers)
  if text then
    lovr.textinput(text, utf8.codepoint(text))
  end
end

function Fixture:nextBatch()
  self.session:update()
end

function Fixture:localTarget(label, handlers, owner)
  local receiver = {
    key = function(event)
      self:record(
        label
          .. ':key:'
          .. event.code
          .. ':'
          .. event.source
          .. ':'
          .. table.concat(event.modifiers, '+')
          .. ':'
          .. tostring(event.isRepeat)
      )
      return if handlers and handlers.key then handlers.key(event) else false
    end,
    text = function(value)
      self:record(label .. ':text:' .. value)
      return if handlers and handlers.text then handlers.text(value) else true
    end,
  }
  return self.focus:register(owner or self.owner, {
    kind = 'local',
    receiver = receiver,
    keymapSeat = self.seat,
    wantsKeyboard = true,
  })
end

function Fixture:close()
  self.closed = true
  self.session:close()
  local reports = self.native.events.reported
  expect.equal(#reports, 0, 'no unexpected callback reports remain after cleanup')
end

return physical
