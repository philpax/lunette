-- Runs the lua/spec/ suite inside the real binary.
--
-- The suite runs through the standard-library mount used by the session.

-- Where the specs are, as a path in the virtual filesystem and as the module
-- prefix that path is reached by. The explicit mount point is the filesystem
-- path as well as the require root.
local SPEC_DIRECTORY = '@spec'
local SPEC_PREFIX = '@spec/'

-- Quit statuses. Distinct from each other so that the run says what went wrong
-- rather than only that something did.
local PASSED = 9
local FAILED = 1
local BROKEN = 2
local EMPTY = 3

-- `lovr.filesystem` under the two names `@spec/runner` asks for. Adapting it
-- here rather than in the runner keeps the runner free of `lovr`, so its
-- discovery is exercised against a table of strings in a spec of its own.
local filesystem = {
    list = function(path)
        return lovr.filesystem.getDirectoryItems(path)
    end,
    isDirectory = function(path)
        return lovr.filesystem.isDirectory(path)
    end,
}

-- Drain temporary vectors between cases because this run has no frame boundary.
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
