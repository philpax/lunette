-- Adopting the windows that were already there.
--
-- A soft reload discards the configuration's modules and callbacks and runs
-- `main.lua` again (docs/lua-api.md#reload). The compositor, the clients, and
-- their windows are untouched by that — which is the point — but the new Lua
-- state knows nothing about them, and `lovr.lunwindowopened` has already been
-- and gone for every one. So a configuration that only ever placed windows from
-- that callback comes back from a reload showing nothing at all.
--
-- This is the other half: `adopt.windows()` is the re-enumeration, and
-- `adopt.install()` is the source that puts a hand-placed panel back where the
-- user left it rather than where a rule would have chosen.
--
-- # Why the store is a source and not a fix-up
--
-- Re-running the rules over a surviving window and then moving it to its stored
-- pose would place it twice, and would place it wrongly for the frame in
-- between. Worse, a rule that spawns something or reads something expensive
-- would run for a window it did not decide anything about.
--
-- So the store is a `mullion.rules` source like any other, above the rules
-- table and above the saved arrangement, and the answer is composed once. A
-- window that has stored state is restored; a window that has none is placed by
-- rule. That is the distinction awesome draws with its startup flag, and it is
-- why the precedence is declarable rather than implicit.
--
-- # What is stored, and by whom
--
-- `mullion.interaction` writes a panel's pose to the native property store when
-- the user drops it, under `interaction.POSE_PROPERTY`. That is the only key
-- mullion writes, so it is the only key this reads. A configuration keeping more
-- of its own — a size it dragged, a tag it assigned — writes its own source
-- against `win:properties()`, which exists so that what survived a reload can be
-- discovered rather than guessed at.
--
-- This module holds no state of its own: the store is native and the source
-- function is pure over a window, so there is nothing a reload could leave
-- behind and no teardown hook to register. The source it installs is
-- `mullion.rules`'s to discard, and that module's hook does.

local lunette = require '@lunette'

local interaction = require '@mullion/interaction'
local panel = require '@mullion/panel'
local rules = require '@mullion/rules'

local adopt = {}

-- The name `install` registers under.
adopt.SOURCE = 'mullion.adopt'

-- Where `install` registers the store source.
--
-- Above `mullion.persist.PRECEDENCE`, and so above `mullion.rules`' own table
-- as well. The store holds what the user did in this session; the file holds
-- what they did in the last one. Where the two disagree the live one is the one
-- they will remember doing.
adopt.PRECEDENCE = 300

-- The properties the native store holds for `window`, or nothing.
--
-- The pose stays the string `mullion.pose` wrote, which is what the store holds
-- and what `mullion.rules` decodes. Handing it through unchanged keeps one
-- encoding rather than two.
function adopt.properties(window: any): { pose: string }?
  if type(window) ~= 'table' and type(window) ~= 'userdata' then
    error('mullion.adopt: a window carries the properties, and a ' .. type(window) .. ' does not', 2)
  end

  local kept = window:getProperty(interaction.POSE_PROPERTY)
  if kept == nil then
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
function adopt.install(precedence)
  rules.addSource(adopt.SOURCE, precedence or adopt.PRECEDENCE, adopt.source())
end

-- The live windows nothing is showing yet, in `lunette.windows()` order.
--
-- What a configuration calls once its rules and sources are installed, so that
-- the windows a reload found already open are placed the way a window opening
-- now would be. The windows rather than panels made from them, because what to
-- do with one is the configuration's decision: `mullion.rules.place` is the
-- usual answer and is not the only one.
--
-- A window that closed while the reload was running is not in the snapshot and
-- so is not resurrected. A window that opened while it was running is, and is
-- picked up here rather than being lost with the `lovr.lunwindowopened` the old
-- state was the last to hear.
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
