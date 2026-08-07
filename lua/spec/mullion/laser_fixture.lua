-- The fake `lunette` the laser specs run against, and the module under test.
--
-- The laser's one native call is `lunette.newSeat`, and the real one asks the
-- compositor for a seat with a keyboard and a pointer. A spec asserting what
-- came back would be asserting Phase 5's work rather than this module's, and a
-- spec run that created seats would leave them behind. So the fake is installed
-- into `package.loaded` before `mullion.laser` is required — which is what the
-- module captures — and `package.loaded.lunette` is put back afterwards, so
-- nothing else in the run sees it.
--
-- Not a spec file: the runner collects `*_spec.lua` and this is not one, so it
-- runs no cases of its own.

local fixture = {}

-- Declared here and defined below, so the surface reads first.
local newSeat

-- Every seat the fake has handed out, newest last.
fixture.seats = {}

local previousLunette = package.loaded.lunette
package.loaded.lunette = {
  newSeat = function(name, options)
    return newSeat(name, options)
  end,
}
package.loaded['mullion.laser'] = nil
fixture.laser = require 'mullion.laser'
package.loaded.lunette = previousLunette

-- Forgets the seats a previous case caused.
function fixture.reset()
  fixture.laser.teardown()
  fixture.seats = {}
end

-- A seat that records what it was asked, and whether it was destroyed.
function newSeat(name, options)
  local seat = {
    name = name,
    options = options,
    dead = false,
    focused = {},
    destroyed = 0,
  }

  function seat:setFocus(sink)
    self.focused[#self.focused + 1] = sink
    return true
  end

  function seat:destroy()
    self.destroyed = self.destroyed + 1
    self.dead = true
    return true
  end

  fixture.seats[#fixture.seats + 1] = seat
  return seat
end

return fixture
