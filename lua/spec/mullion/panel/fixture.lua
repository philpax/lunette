-- The fakes the panel, interaction, and laser specs share, and the panel module
-- under test.
--
-- The panel's one native call is `lunette.claimLayer`, so `lunette` is faked.
-- The native call answers against the session's layer pool, and a spec run has
-- no headset; an assertion about what the pool granted would test the pool,
-- not the module. The fixture installs the fake into `package.loaded` first,
-- so the require of `mullion.panel` captures it. The original
-- `package.loaded['@lunette']` entry is restored afterwards, so nothing else
-- in the run reads the fake.
--
-- Both panel specs require the fake through this module. Two installs would
-- leave two `mullion.panel` module tables with separate panel lists, and a case
-- in one would then reason about the other's state.
--
-- Not a spec file: the runner collects `*_spec.lua` and this is not one, so it
-- runs no cases of its own.

local fixture = {}

-- Declared here and defined below.
local newClaim, newLayer

-- The fake `lunette` appends every claim to this list, newest last. A case
-- reads the claim its call caused. The panel requests the claim, and the case
-- asserts what the panel asked for.
fixture.claims = {}

-- How close two metre or pixel quantities must be to count as equal. Every
-- number the geometry produces comes from a 4x4 inversion, so an exact
-- comparison would assert the order of the operations.
fixture.TOLERANCE = 1e-4

-- What the fake `lunette.windows()` answers, and what `mullion.adopt`
-- re-enumerates. Each call returns a fresh array, as the native function does.
fixture.windows = {}

local previousLunette = package.loaded['@lunette']
package.loaded['@lunette'] = {
  claimLayer = function(options)
    return newClaim(options)
  end,
  windows = function()
    local listed = {}
    for index, window in ipairs(fixture.windows) do
      listed[index] = window
    end
    return listed
  end,
}
package.loaded['@mullion/panel'] = nil
package.loaded['@mullion/adopt'] = nil
fixture.panel = require '@mullion/panel'
-- Required inside the same window, so the `lunette` it captures is this fake
-- and the `mullion.panel` it captures is the one above.
fixture.adopt = require '@mullion/adopt'
package.loaded['@lunette'] = previousLunette

-- A pixel source. Windows and monitors both carry these fields, so one panel
-- implementation does both.
function fixture.newSource(width, height, options)
  local source = {
    dead = false,
    width = width,
    height = height,
    title = 'a source',
    sink = { name = 'a sink' },
    texture = options and options.texture or nil,
    -- A buffer whose fourth component is padding, not alpha. The quad path
    -- draws an opaque source with a shader that forces alpha to one; the
    -- padding byte is never sampled.
    opaque = options and options.opaque or nil,
  }

  function source:getTexture()
    return self.texture or false
  end

  return source
end

-- A sink that records the calls it receives, in order.
--
-- Every method takes the trailing seat the native ones take, and records it. A
-- pointer that omitted its seat would address the seat the session
-- starts with, so two hands would share one cursor and one focus. That is the
-- defect two seats exist to avoid: it is invisible unless a spec looks.
function fixture.newSink()
  local sink = { calls = {}, seats = {} }

  local function record(name)
    return function(self, ...)
      local arguments = { ... }
      self.calls[#self.calls + 1] = { name = name, arguments = arguments }
      self.seats[#self.seats + 1] = arguments[#arguments]
      return true
    end
  end

  sink.pointer = record 'pointer'
  sink.button = record 'button'
  sink.leave = record 'leave'
  sink.scroll = record 'scroll'
  sink.key = record 'key'
  sink.modifiers = record 'modifiers'
  sink.typeText = record 'typeText'

  return sink
end

-- How many windows this fixture has made; that count is the source of their
-- identifiers. A window carries one in a session and `mullion.panel.forSource`
-- matches on it; a fixture window without one would make two windows look like
-- one.
local minted = 0

-- A window source with a recording sink and the native property store.
function fixture.newWindow(width, height)
  local window = fixture.newSource(width, height)
  window.sink = fixture.newSink()
  window.stored = {}
  minted = minted + 1
  window.id = minted

  function window:setProperty(key, value)
    if self.dead then
      return false
    end
    self.stored[key] = value
    return true
  end

  function window:getProperty(key)
    return self.stored[key]
  end

  return window
end

-- The same source, wrapped in the userdata a session returns.
--
-- `lunette.windows()` and `event.window` answer an mlua `UserData`
-- (`crates/lunette/src/lua/window.rs`), so `type(window)` is `'userdata'`, not
-- `'table'`. A fixture that mints no userdata cannot distinguish a module
-- that indexes its argument from a module that expects a table argument; the
-- second form rejects every real window. Reads and writes pass through to
-- `source`, so a case can still inspect what a module did to it.
--
-- `newproxy` is Lua 5.1's, which is LuaJIT's, and is the way to mint a
-- userdata from Lua. Nothing in the standard library may depend on it. The
-- specs use it to present the same userdata shape a session produces.
function fixture.asHandle(source)
  local handle = newproxy(true)
  local meta = getmetatable(handle)
  meta.__index = source
  meta.__newindex = source
  return handle
end

-- The names of a sink's calls, in order, as one string. A spec asserting the
-- whole sequence catches a call that should not have happened, as well as one
-- that should have.
function fixture.sequence(sink)
  local names = {}
  for index, call in ipairs(sink.calls) do
    names[index] = call.name
  end
  return table.concat(names, ',')
end

-- The last call of `name` in the sink's record, or nothing.
function fixture.lastCall(sink, name)
  for index = #sink.calls, 1, -1 do
    if sink.calls[index].name == name then
      return sink.calls[index]
    end
  end
  return nil
end

-- A LÖVR `Pass` that records the calls it receives.
--
-- A call the code under test makes that this fake does not have raises. A fake
-- that answered every call would let a typo through.
--
-- `lines` and `spheres` keep their arguments, because the position of a
-- laser's beam is the whole of what the drawing does.
function fixture.newPass()
  local pass = { planes = 0, texts = 0, lines = {}, spheres = {}, material = nil, shaders = {} }

  function pass:plane()
    self.planes = self.planes + 1
  end

  function pass:text()
    self.texts = self.texts + 1
  end

  function pass:line(...)
    self.lines[#self.lines + 1] = { ... }
  end

  function pass:sphere(...)
    self.spheres[#self.spheres + 1] = { ... }
  end

  function pass:setMaterial(material)
    -- Recorded on entry and not cleared on exit, so a case can ask what was
    -- bound when the draw returned.
    if material then
      self.material = material
    end
  end

  function pass:setColor() end
  function pass:setBlendMode() end
  function pass:setDepthTest() end
  function pass:setDepthWrite() end

  -- Every shader set and every clear, in order: a draw that set one and did not
  -- clear it would leave it on the pass for whatever the configuration draws
  -- next, and a spec that looked at just the last value would not see that.
  function pass:setShader(shader)
    self.shaders[#self.shaders + 1] = shader or false
  end

  return pass
end

-- A pose, as a permanent matrix, so it survives LÖVR's temporary pool being
-- drained between cases.
function fixture.poseAt(x, y, z)
  return lovr.math.newMat4():translate(x or 0, y or 0, z or 0)
end

-- Destroys all state an earlier case left, so `panel.all` and `fixture.claims`
-- concern this case alone.
function fixture.reset()
  fixture.panel.teardown()
  fixture.claims = {}
  fixture.windows = {}
end

-- A claim that holds no layer until a case grants it one.
--
-- `width` and `height` report the layer's size, not the requested one, as the
-- real handle does: requests are quantised up a ladder, and the viewport
-- excludes the gap between the requested and the granted size.
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

  -- Grants a layer of `width` by `height`, the rung the ladder quantises a
  -- request to.
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

-- A LÖVR `Layer` that records the calls it receives.
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
