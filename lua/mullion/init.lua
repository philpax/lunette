-- The mullion standard library.
--
-- mullion is policy written in Lua over the `lunette` native API, and it uses
-- nothing that is not in docs/lua-api.md. lunette is mechanism; mullion is what
-- decides. A configuration may use as much or as little of it as it likes, and a
-- configuration that never mentions it at all is supported.
--
-- This root module is what `require 'mullion'` resolves to, and its presence is
-- what makes the mount in crates/lunette/src/boot.rs observable. It holds no
-- state, registers no signal connection, and starts nothing, so it has no
-- teardown hook to register: there is nothing a reload could leave behind.
--
-- Submodules are required by their own paths — `require 'mullion.signal'`,
-- `require 'mullion.layout.arc'` — rather than being re-exported here. The
-- tiers are independent, and a configuration that wants signals should not load
-- the layout engine to get them.

local mullion = {}

return mullion
