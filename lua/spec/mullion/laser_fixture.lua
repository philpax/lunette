-- The fake `lunette` the laser specs run against, and the module under test.
--
-- The laser's one native call is `lunette.newSeat`.
-- The production `lunette.newSeat` creates a seat in the compositor.
-- The seat has a keyboard and a pointer.
-- A spec that asserts the returned seat would test the compositor's work, not
-- the laser module's. A spec run that creates a seat leaves it in the
-- compositor. The fixture installs the fake into `package.loaded` and then
-- requires `mullion.laser`. The module's require of `@lunette` returns the
-- fake. The fixture restores `package.loaded['@lunette']` afterwards. A later
-- require of `@lunette` resolves to the production module.
--
-- The runner collects `*_spec.lua`, and the fixture is not one. It runs no
-- cases of its own.

local fixture = {}

-- Forward-declared so the fixture surface appears first.
local newSeat

-- Every seat the fake created, newest last.
fixture.seats = {}

local previousLunette = package.loaded['@lunette']
package.loaded['@lunette'] = {
  newSeat = function(name, options)
    return newSeat(name, options)
  end,
}
package.loaded['@mullion/laser'] = nil
fixture.laser = require '@mullion/laser'
package.loaded['@lunette'] = previousLunette

-- Empties the seats earlier cases created.
function fixture.reset()
  fixture.laser.teardown()
  fixture.seats = {}
end

-- A seat that records its name and options, and whether something destroyed it.
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
