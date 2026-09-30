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

local clock = plugin.capability('fixture/clock', 1, function(value: Clock): Clock
  return value
end)

local log = plugin.capability('fixture/log', 1, function(value: Log): Log
  return value
end)

local function config(value: Config): Config
  return value
end

return { clock = clock, log = log, config = config }
