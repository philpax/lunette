-- Recreates the benchmark's runtime and callbacks after the host clears source modules.
local host = require '@testing/host'
local scene = require './scene'

local stable = assert(host.benchmark, 'benchmark: the session fixtures are missing')
assert(stable.current == nil, 'benchmark: main cannot replace an active workload')
stable.current = scene.prepareEpoch(stable)
