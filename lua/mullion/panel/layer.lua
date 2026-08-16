-- The composition layer a window panel draws on: claiming one, keeping the
-- claim in step with the source, and driving what it was granted.
--
-- Split from `mullion.panel` because the two halves have nothing in common.
-- That one is a pose, a size, and a source; this is a claim against a pool of
-- a fixed size, which is granted and revoked on frame boundaries by something
-- else. Grants land between frames and never mid-frame
-- (docs/lua-api.md#layer-claims), so this reads `claim.granted` each update
-- rather than handling `lunette.onLayerGranted`.
--
-- A monitor panel never reaches here. `lunette.claimLayer` takes a window and
-- nothing else, so a mirrored screen has no way to ask for a layer and draws as
-- a quad. That is a gap in the native API rather than a decision made here.

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
-- A window whose client resized past the layer it was granted needs a claim on
-- a larger rung, and the pool has no way to grow one underneath it: a claim
-- names a key, and the key carries the size. So the claim is released and
-- remade, which costs a frame or two on the quad path.
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
    -- quantises upwards, so this is the resized-past-its-rung case.
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

  -- On every grant and on every resize, which is what this phase owes Phase 3.
  -- The size ladder quantises upwards, so the layer is usually larger than the
  -- source and the blit lands at the layer's origin; the viewport is what
  -- excludes the margin. The blit clears that margin, but blank is not the same
  -- as absent — an 800x600 window in a 1024x1024 layer would otherwise be drawn
  -- squeezed into the top-left corner of a square.
  if resized or not self.granted then
    held:setViewport(0, 0, pixelWidth, pixelHeight)
    self.appliedWidth, self.appliedHeight = pixelWidth, pixelHeight
  end

  held:setPosition(self.pose:getPosition())
  -- As an angle and an axis, which is what `Mat4:getOrientation` hands back and
  -- what `luax_readquat` takes from four numbers. `lovr.math.quat` does not
  -- construct from a `Mat4`.
  held:setOrientation(self.pose:getOrientation())
  held:setDimensions(self.width, self.height)

  signal.setProperty(self, 'granted', true)
  return true
end

return layer
