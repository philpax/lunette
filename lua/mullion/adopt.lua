-- Adopt windows that were already open when the current Lua state started.
--
-- The native property store is a rules source. Stored poses take precedence over
-- the saved arrangement and ordinary rules, so a hand-placed panel is restored
-- without applying another placement first.

local lunette = require '@lunette'

local interaction = require '@mullion/interaction'
local panel = require '@mullion/panel'
local rules = require '@mullion/rules'

local adopt = {}

-- The name `install` registers under.
adopt.SOURCE = 'mullion.adopt'

-- Where `install` registers the store source.
--
-- Above `mullion.persist.PRECEDENCE`, and so above the `mullion.rules` table
-- as well. The store records what the user changed in this session, and the
-- file records what they changed in the last one. When the two disagree, the
-- live store holds the more recent change.
adopt.PRECEDENCE = 300

-- The properties the native store holds for `window`, or nothing.
--
-- The pose stays the string `mullion.pose` wrote, which is what the store holds
-- and what `mullion.rules` decodes. Handing it through unchanged keeps one
-- encoding rather than two.
function adopt.properties(window: lunette.Window): rules.Resolved?
  -- Through a local, so that the test does not narrow `window` itself: a
  -- handle is userdata, and refining on that loses the fields it carries.
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('mullion.adopt: a window carries the properties, and a ' .. kind .. ' does not', 2)
  end

  -- The store holds booleans and numbers too, and a pose written by anything
  -- but `mullion.pose` is not one this can hand on: `rules` decodes a string.
  local kept = window:getProperty(interaction.POSE_PROPERTY)
  if type(kept) ~= 'string' then
    return nil
  end
  return { pose = kept }
end

-- A `mullion.rules` source over the native property store.
--
-- Stateless, unlike `mullion.persist.source`: the store is keyed by window and
-- answers the same thing however many times it is asked, so there is no slot to
-- assign and nothing to remember.
function adopt.source()
  return adopt.properties
end

-- Registers the store source with `mullion.rules`.
--
-- `precedence` defaults to `adopt.PRECEDENCE`. Passing a lower one is how a
-- configuration says that its rules should beat what the user last dragged the
-- window to.
function adopt.install(precedence: number?)
  rules.addSource(adopt.SOURCE, precedence or adopt.PRECEDENCE, adopt.source())
end

-- Returns live windows that do not already have panels, in enumeration order.
-- The caller decides how to place them after installing its rules and sources.
function adopt.windows()
  local pending = {}
  for _, window in ipairs(lunette.windows()) do
    if not window.dead and not panel.forSource(window) then
      pending[#pending + 1] = window
    end
  end
  return pending
end

return adopt
