local plugin = require '@lunette-plugin'

type Service = { read count: (Service) -> number }
local named = plugin.capability<<Service>> { name = 'fixture/named', schema = 1 }
local unnamed = plugin.capability { name = 'fixture/unnamed', schema = 1 } -- reject: service type is unknown.
return { named = named, unnamed = unnamed }
