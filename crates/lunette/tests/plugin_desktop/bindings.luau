-- Key bindings: a configured reload chord, a plugin's chords consumed before
-- delivery, repeats, a raising binding, and validation.
local plugin = require '@lunette-plugin'
local bindingsContract = require '@lunette-contracts/bindings'

local ran = {}
local service, owner
local hotkeys = plugin.define {
  name = 'hotkeys',
  requires = { bindings = bindingsContract.capability },
  init = function(context)
    service, owner = context:require(bindingsContract.capability), context
    service:register(context, {
      chord = { key = 'backspace', modifiers = { 'alt', 'control' } },
      run = function(press)
        ran[#ran + 1] = press
      end,
    })
    service:register(context, {
      chord = { key = 'f9' },
      run = function()
        error 'binding failure'
      end,
    })
  end,
}
local desktop = require 'fixture/graph' {
  patches = {
    { id = 'desktop/bindings', config = { reload = { key = 'r', modifiers = { 'control' } } } },
    { insert = { id = 'hotkeys', definition = hotkeys } },
  },
}

-- The reload chord is the configured one, and F5 is unbound.
local function bound(key, modifiers)
  for _, chord in ipairs(service:chords()) do
    if chord.key == key and table.concat(chord.modifiers, '+') == table.concat(modifiers, '+') then
      return true
    end
  end
  return false
end
assert(bound('r', { 'control' }), 'the reload chord is configurable')
assert(not bound('f5', {}), 'the default reload key is replaced, not added to')
assert(not service:dispatch { key = 'f5', modifiers = {}, isRepeat = false }, 'an unbound press is not consumed')

-- Focus a window, so keys would reach it if no binding took them.
local window = newWindow(1)
events.windows = { window }
emit('onWindowOpened', { window = window })
lovr.update(0.016)
events.trigger = true
lovr.update(0.016)
events.trigger = false
lovr.update(0.016)
local before = #events.input
lovr.keypressed('backspace', 0, false)
assert(#events.input > before, 'an unbound key reaches the focused window')

-- A chord matches its key with exactly its modifiers held, whatever order
-- they were written in, and the press goes no further.
events.held.lctrl, events.held.lalt = true, true
before = #events.input
lovr.keypressed('backspace', 0, false)
assert(#ran == 1 and ran[1].key == 'backspace', 'the binding ran')
assert(#events.input == before, 'a bound press does not reach the client')
lovr.keypressed('backspace', 0, true)
assert(#ran == 1 and #events.input == before, 'a repeat is consumed and does not run again')
events.held.lshift = true
lovr.keypressed('backspace', 0, false)
assert(#ran == 1 and #events.input > before, 'another modifier set is another chord')
events.held = {}
assert(not pcall(function()
  service:register(owner, { chord = { key = 'backspace', modifiers = { 'control', 'alt' } }, run = function() end })
end), 'a chord is bound once')

-- A binding that raises is reported, and its press is still consumed.
events.reported = {}
before = #events.input
lovr.keypressed('f9', 0, false)
assert(#events.reported == 1 and events.reported[1].message:find('binding failure', 1, true))
assert(#events.input == before)

-- Malformed registrations raise at the call.
for _, binding in ipairs {
  { chord = { key = '' }, run = function() end },
  { chord = { key = 'x', modifiers = { 'hyper' } }, run = function() end },
  { chord = { key = 'x', modifiers = { 'alt', 'alt' } }, run = function() end },
  { chord = { key = 'x', modifier = { 'alt' } }, run = function() end },
  { chord = { key = 'x' }, run = 'reload' },
  { chord = { key = 'x' }, run = function() end, when = true },
} do
  assert(not pcall(function()
    service:register(owner, binding)
  end))
end

-- A binding ends with its owner.
desktop.instances.hotkeys:disable()
events.held.lctrl, events.held.lalt = true, true
assert(not service:dispatch { key = 'backspace', modifiers = { 'control', 'alt' }, isRepeat = false })
events.held = {}

-- The broker takes presses itself, so input does not require it: a bindings
-- outage takes the desktop's bindings away and leaves typing working.
desktop.providers.bindings:disable()
assert(desktop.consumers.bindings:state() ~= 'active', 'the desktop bindings need the broker')
assert(desktop.consumers.input:state() == 'active', 'input does not need the broker')
assert(desktop.consumers.render:state() == 'active')
before = #events.input
lovr.keypressed('backspace', 0, false)
assert(#events.input > before, 'a key reaches the focused window during a bindings outage')
desktop.providers.bindings:enable()
assert(desktop.consumers.input:state() == 'active' and desktop.consumers.bindings:state() == 'active')
assert(lovr.quit() == false)
