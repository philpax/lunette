-- The fakes the panel specs share, and the module under test.
--
-- The panel's one native call is `lunette.claimLayer`, so `lunette` is faked:
-- the real one would hand back a claim against a layer pool with no headset
-- behind it, and a spec asserting what the pool did would be asserting Phase
-- 3's work rather than this module's. The fake is installed into
-- `package.loaded` before `mullion.panel` is required, which is what the module
-- captures, and `package.loaded.lunette` is put back afterwards so nothing else
-- in the run sees it.
--
-- This is required by both panel specs rather than each installing its own
-- fake, because two installs would leave two `mullion.panel` module tables with
-- separate panel lists, and a case in one would then be reasoning about the
-- other's state.
--
-- Not a spec file: the runner collects `*_spec.lua` and this is not one, so it
-- runs no cases of its own.

local fixture = {}

-- Declared here and defined below, so the surface reads first.
local newClaim, newLayer

-- Every claim the fake `lunette` has handed out, newest last. A case reads the
-- one it caused rather than being handed it, because the panel makes the claim
-- and the spec's business is what it asked for.
fixture.claims = {}

-- How close two metre or pixel quantities have to be to count as equal. Every
-- number the geometry produces came out of a 4x4 inversion, so an exact
-- comparison would be asserting the order the operations were written in.
fixture.TOLERANCE = 1e-4

local previousLunette = package.loaded.lunette
package.loaded.lunette = {
  claimLayer = function(options)
    return newClaim(options)
  end,
}
package.loaded['mullion.panel'] = nil
fixture.panel = require 'mullion.panel'
package.loaded.lunette = previousLunette

-- A pixel source. Windows and monitors both carry these fields, which is what
-- lets one panel implementation serve both.
function fixture.newSource(width, height, options)
  local source = {
    dead = false,
    width = width,
    height = height,
    title = 'a source',
    sink = { name = 'a sink' },
    texture = options and options.texture or nil,
  }

  function source:getTexture()
    return self.texture or false
  end

  return source
end

-- A LÖVR `Pass` that records what it was asked to draw.
--
-- The panel calls `plane`, `text`, `setMaterial`, `setColor`, and
-- `setBlendMode`, so those are all this carries: a call the panel makes and
-- this does not have raises, which is the report wanted.
function fixture.newPass()
  local pass = { planes = 0, texts = 0, material = nil }

  function pass:plane()
    self.planes = self.planes + 1
  end

  function pass:text()
    self.texts = self.texts + 1
  end

  function pass:setMaterial(material)
    -- Recorded on the way in and not cleared on the way out, so a case can ask
    -- what was bound after the draw returned.
    if material then
      self.material = material
    end
  end

  function pass:setColor() end
  function pass:setBlendMode() end

  return pass
end

-- A pose, as a permanent matrix so that it survives LÖVR's temporary pool being
-- drained between cases.
function fixture.poseAt(x, y, z)
  return lovr.math.newMat4():translate(x or 0, y or 0, z or 0)
end

-- Destroys everything a previous case left behind, so that `panel.all` and the
-- claim log are about this case alone.
function fixture.reset()
  fixture.panel.teardown()
  fixture.claims = {}
end

-- A claim that holds no layer until a case grants it one.
--
-- `width` and `height` report the layer's size rather than the requested one,
-- as the real handle does: requests are quantised up a ladder, and the gap
-- between what was asked for and what arrived is what the viewport exists to
-- exclude.
function newClaim(options)
  local claim = {
    granted = false,
    layer = false,
    width = options.width,
    height = options.height,
    window = options.window,
    priority = options.priority,
    requestedWidth = options.width,
    requestedHeight = options.height,
    released = false,
  }

  function claim:setPriority(priority)
    self.priority = priority
  end

  function claim:release()
    self.released = true
    self.granted = false
    self.layer = false
  end

  -- Grants a layer of `width` by `height`, which is the rung the ladder
  -- quantised the request up to.
  function claim:grant(width, height)
    self.width = width or self.width
    self.height = height or self.height
    self.granted = true
    self.layer = newLayer()
    return self.layer
  end

  function claim:revoke()
    self.granted = false
    self.layer = false
  end

  fixture.claims[#fixture.claims + 1] = claim
  return claim
end

-- A LÖVR `Layer` that records what it was told.
function newLayer()
  local layer = { viewports = {}, dimensions = nil, positions = {}, orientations = 0 }

  function layer:setViewport(x, y, width, height)
    self.viewports[#self.viewports + 1] = { x = x, y = y, width = width, height = height }
  end

  function layer:setDimensions(width, height)
    self.dimensions = { width = width, height = height }
  end

  function layer:setPosition(x, y, z)
    self.positions[#self.positions + 1] = { x = x, y = y, z = z }
  end

  function layer:setOrientation()
    self.orientations = self.orientations + 1
  end

  return layer
end

return fixture
