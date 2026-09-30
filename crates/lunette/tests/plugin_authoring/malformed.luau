local plugin = require '@lunette-plugin'
local contracts = require './contracts'

local notCapability: plugin.Declaration = { clock = 'clock' } -- reject: string.
local nested: plugin.Declaration = { group = { clock = contracts.clock } } -- reject: witness.
local wrongWitness: plugin.Declaration = { clock = { witness = 42 } } -- reject: number.
return { notCapability, nested, wrongWitness }
