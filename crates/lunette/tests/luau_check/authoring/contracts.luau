local plugin = require '@lunette-plugin'

export type Clock = {
  read now: (Clock) -> number,
}

export type Log = {
  read write: (Log, string) -> (),
}

export type Config = {
  read prefix: string,
}

export type ChildConfig = {
  read enabled: boolean,
}

local clock = plugin.capability<<Clock>> { name = 'fixture/clock', version = 1 }

local log = plugin.capability<<Log>> { name = 'fixture/log', version = 1 }

return { clock = clock, log = log }
