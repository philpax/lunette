-- Adopt the windows already open when the current Lua state started.
--
-- A soft reload discards the configuration's modules and callbacks and runs
-- `main.lua` again (docs/lua-api.md#reload). The compositor, the clients, and
-- their windows are untouched by the reload, but the new Lua state has no
-- record of them, and `lunette.onWindowOpened` has already run for every one.
-- A configuration that places windows through that callback alone ends the
-- reload with no windows.
--
-- This module is the counterpart: `adopt.windows()` re-enumerates the windows,
-- and `adopt.install()` registers the source that returns a hand-placed panel
-- to where the user left it.
--
-- # The store as a source, not a fix-up
--
-- Running the rules over a surviving window and then moving it to its stored
-- pose would place it twice, with the wrong pose for the frame in between.
-- A rule that spawns something or reads something expensive would also run
-- for a window it does not place.
--
-- The store is a `mullion.rules` source like any other, above the rules table
-- and above the saved arrangement, and the answer is composed once. A
-- window that has stored state is restored; a window that has none is placed by
-- rule. Awesome's startup flag marks the same distinction, and the source
-- precedence makes the ordering declarable.
--
-- # Stored data and its writers
--
-- `mullion.interaction` writes a panel's pose to the native property store when
-- the user drops it, under `interaction.POSE_PROPERTY`. That key is the sole
-- key mullion writes, and the sole key this module reads. A configuration
-- keeping more of its own (a size it dragged, a tag it assigned) writes its own
-- source against `win:properties()`. That read returns what survived the
-- reload.
--
-- This module holds no state of its own: the store is native and the source
-- function is pure over a window, so there is no state for the reload to
-- discard and no teardown hook is registered. The source it installs is
-- discarded by `mullion.rules`'s teardown hook, which clears the source list.

local lunette = require '@lunette'

local interaction = require '@mullion/interaction'
local panel = require '@mullion/panel'
local rules = require '@mullion/rules'

local adopt = {}

-- The name `install` registers under.
adopt.SOURCE = 'mullion.adopt'

-- Where `install` registers the store source.
--
-- Above `mullion.persist.PRECEDENCE`, and above `mullion.rules`' own table.
-- The store holds what the user did in this session; the file holds what they
-- did in the last one. Where the two disagree, the store holds the newer
-- change.
adopt.PRECEDENCE = 300

-- The properties the native store holds for `window`, or nothing.
--
-- The pose is the string `mullion.pose` writes. The store holds that string,
-- and `mullion.rules` decodes it. Handing it through unchanged avoids a second
-- encoding.
function adopt.properties(window: lunette.Window): rules.Resolved?
  -- The kind goes through a local. Narrowing `window` itself removes the
  -- fields a handle carries, because a handle is userdata.
  local kind = type(window)
  if kind ~= 'table' and kind ~= 'userdata' then
    error('mullion.adopt: a window carries the properties, and a ' .. kind .. ' does not', 2)
  end

  -- The store holds booleans and numbers too. `rules` decodes a string, so the
  -- function returns nothing for a pose it holds as a boolean or a number.
  local kept = window:getProperty(interaction.POSE_PROPERTY)
  if type(kept) ~= 'string' then
    return nil
  end
  return { pose = kept }
end

-- A `mullion.rules` source over the native property store.
--
-- Stateless, unlike `mullion.persist.source`: the store is keyed by window and
-- returns the same value on every call, so there is no slot to assign and
-- nothing to keep.
function adopt.source()
  return adopt.properties
end

-- Registers the store source with `mullion.rules`.
--
-- `precedence` defaults to `adopt.PRECEDENCE`. Passing a lower one gives the
-- configuration's rules priority over what the user last dragged the window
-- to.
function adopt.install(precedence: number?)
  rules.addSource(adopt.SOURCE, precedence or adopt.PRECEDENCE, adopt.source())
end

-- The live windows without a panel, in `lunette.windows()` order.
--
-- A configuration calls it once its rules and sources are installed. The
-- windows a reload found already open are then placed the way a window opening
-- now would be. The function returns windows, not panels; what to do with one
-- is the configuration's decision. `mullion.rules.place` is the usual answer,
-- and other answers exist.
--
-- A window that closes during the reload is not in the snapshot and is not
-- resurrected. A window that opens during the reload is in the snapshot and is
-- adopted. The `lunette.onWindowOpened` for it ran in the old state, which the
-- reload discarded.
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
