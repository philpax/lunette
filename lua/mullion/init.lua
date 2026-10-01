-- The mullion standard library.
--
-- mullion is optional policy written in Lua over the `lunette` native API. It
-- uses nothing outside docs/dev/lua-api.md. lunette is mechanism; mullion is
-- policy. A configuration may use any part of the library, or none of it, and
-- neither the built-in providers nor the desktop require it.
--
-- `require '@mullion'` resolves to the root module through the mount in
-- crates/lunette/src/boot.rs. It holds no state and starts nothing, so a
-- reload has nothing to leave behind.
--
-- A configuration requires each submodule by its own path, for example
-- `require '@mullion/scale'` and `require '@mullion/pacing'`. The root module
-- does not re-export submodules, so a configuration that chooses scales does
-- not load the pacer.

local mullion = {}

return mullion
