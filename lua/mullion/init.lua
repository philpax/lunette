-- The mullion standard library.
--
-- mullion is policy written in Lua over the `lunette` native API. It uses
-- nothing outside docs/lua-api.md. lunette is mechanism; mullion is policy.
-- A configuration may use any part of the library, or none of it.
--
-- `require '@mullion'` resolves to the root module through the mount in
-- crates/lunette/src/boot.rs. It holds no state, registers no signal
-- connection, and starts nothing. It registers no teardown hook, because a
-- reload has nothing to leave behind.
--
-- A configuration requires each submodule by its own path, for example
-- `require '@mullion/signal'` and `require '@mullion/layout/arc'`. The root
-- module does not re-export submodules. The tiers are independent. A
-- configuration that uses signals does not load the layout engine.

local mullion = {}

return mullion
