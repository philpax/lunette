-- Composition layers for window panels.
--
-- Claims are granted and revoked between frames. The panel reads `claim.granted`
-- during each update.

local lunette = require '@lunette'

local signal = require '@mullion/signal'

local layer = {}

-- A layer claim, as `lunette.claimLayer` answers. Structural rather than
-- `lunette.Claim` itself, because a source a configuration wrote may hand a
-- panel a claim of its own that is not the native one.
export type Claim = {
  read granted: boolean?,
  read width: number?,
  read height: number?,
  read layer: Layer | false,
  -- The result is unused; `...any` so that a claim answering nothing and the
  -- native one answering a boolean both fit.
  read release: (any) -> ...any,
}
-- What the layer half of a panel reads and writes.
--
-- The fields it writes are named as they are on a panel, because it writes
-- them: a claim, the size that was last applied to the layer, and whether the
-- panel is on one. The rest it only reads.
export type Claimant = {
  read kind: 'window' | 'monitor',
  read source: lunette.Window | lunette.Monitor,
  read pose: Mat4,
  read width: number,
  read height: number,
  read priority: number,
  claim: Claim?,
  appliedWidth: number?,
  appliedHeight: number?,
  granted: boolean,
}

-- Keeps the layer claim in step with the source's pixel size.
--
-- A window whose client resized past the layer it was granted needs a claim
-- on a larger size class, and the pool cannot enlarge an existing claim in
-- place: a claim names a key, and the key carries the size. The claim is
-- therefore released and remade, which costs a frame or two on the quad path.
function layer.sync(self: Claimant, pixelWidth: number, pixelHeight: number)
  -- `lunette.claimLayer` takes a window and nothing else, so a monitor panel
  -- has no claim to keep in step. Noted at the module head as a gap in the
  -- native API rather than a choice made here.
  if self.kind ~= 'window' then
    return
  end

  if self.claim then
    local layerWidth: number? = self.claim.width
    local layerHeight: number? = self.claim.height
    -- A layer smaller than the source would crop it, and the ladder only
    -- quantises upwards, so this is the case of a source resized past its layer.
    if layerWidth and layerHeight and (pixelWidth <= layerWidth and pixelHeight <= layerHeight) then
      return
    end
    self.claim:release()
    self.claim = nil
    signal.setProperty(self, 'granted', false)
    self.appliedWidth, self.appliedHeight = nil, nil
  end

  self.claim = lunette.claimLayer {
    window = self.source :: lunette.Window,
    width = pixelWidth,
    height = pixelHeight,
    priority = self.priority,
  }
end

-- Drives the layer this panel holds, and answers whether it is on one.
--
-- Called each update after `sync`, with the source's pixel size.
function layer.drive(self: Claimant, pixelWidth: number, pixelHeight: number): boolean
  if not self.claim then
    return false
  end

  local granted = self.claim.granted and true or false
  local resized = self.appliedWidth ~= pixelWidth or self.appliedHeight ~= pixelHeight

  if not granted then
    self.appliedWidth, self.appliedHeight = nil, nil
    signal.setProperty(self, 'granted', false)
    return false
  end

  -- Never cached across frames: `claim.layer` names something that goes away on
  -- revoke, and re-acquiring it is cheap.
  local held = self.claim.layer
  if not held then
    return false
  end

  -- The quantised layer can exceed the source size. Match the viewport to the
  -- source so the runtime does not squeeze it into the larger layer.
  if resized or not self.granted then
    held:setViewport(0, 0, pixelWidth, pixelHeight)
    self.appliedWidth, self.appliedHeight = pixelWidth, pixelHeight
  end

  held:setPosition(self.pose:getPosition())
  -- Apply the pose using the orientation representation expected by the layer.
  held:setOrientation(self.pose:getOrientation())
  held:setDimensions(self.width, self.height)

  signal.setProperty(self, 'granted', true)
  return true
end

return layer
