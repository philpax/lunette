-- Runs the lua/spec/ suite inside the binary, not inside a Lua state a test
-- built.
--
-- The suite lives in the repository's `lua/` tree, which reaches this session
-- through LUNETTE_STDLIB_PATH, so `@spec/runner` and `@mullion/signal` both
-- resolve through the same mount a session resolves the standard library
-- through. The specs run against the tree as it is installed, not against a copy
-- assembled for them.
--
-- The devshell ships no standalone LuaJIT, and the mount is LÖVR's virtual
-- filesystem, not the process's, so there is nowhere else this could run.
-- crates/lunette/tests/mullion_spec.rs is the caller.

-- The specs live at `@spec` in the virtual filesystem, and `@spec/` is the
-- module prefix that path is reached by. The explicit mount point is the
-- filesystem path as well as the require root.
local SPEC_DIRECTORY = '@spec'
local SPEC_PREFIX = '@spec/'

-- Quit statuses, each distinct so the run reports which stage failed. A
-- shared status would not name the failed stage.
local PASSED = 9
local FAILED = 1
local BROKEN = 2
local EMPTY = 3

-- The adapter stands in for `lovr.filesystem` under the two names
-- `@spec/runner` asks for. It keeps the runner free of `lovr`, so its
-- discovery is exercised against a table of strings in a spec of its own.
local filesystem = {
    list = function(path)
        return lovr.filesystem.getDirectoryItems(path)
    end,
    isDirectory = function(path)
        return lovr.filesystem.isDirectory(path)
    end,
}

-- LÖVR hands out temporary vectors from a fixed pool and drains it at each
-- frame boundary. This run never reaches one, so it drains between cases; a
-- panel spec raycasting a few dozen times would otherwise exhaust the pool part
-- way through the suite. The failure would then be an arithmetic error, and
-- an arithmetic error does not identify the pool as the cause.
local function drainTemporaries()
    if lovr.math and lovr.math.drain then
        lovr.math.drain()
    end
end

function lovr.load()
    local runner = require '@spec/runner'

    local names = runner.discover(filesystem, SPEC_DIRECTORY, SPEC_PREFIX)
    if #names == 0 then
        print('no spec files were found under ' .. SPEC_DIRECTORY)
        lovr.event.quit(EMPTY)
        return
    end

    local collected, suites = pcall(runner.collect, names)
    if not collected then
        print('a spec file could not be loaded: ' .. tostring(suites))
        lovr.event.quit(BROKEN)
        return
    end

    local results = runner.run(suites, drainTemporaries)
    print(runner.format(results))
    lovr.event.quit(#results.failures == 0 and PASSED or FAILED)
end
