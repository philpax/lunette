-- Ownership is checked at the call site for each compositor layer claim operation.

local lunette = require '@lunette'

local layer = {}

export type Claim = lunette.Claim

-- The pixel rectangle of the layer that the panel shows.
export type Viewport = { read x: number, read y: number, read width: number, read height: number }

type ClaimantFields = {
  read pose: Mat4,
  read width: number,
  read height: number,
  read priority: number,
  claim: Claim?,
  appliedViewport: Viewport?,
  granted: boolean,
}

export type Claimant =
  ClaimantFields
  & ({ read kind: 'window', read source: lunette.Window } | { read kind: 'monitor', read source: lunette.Monitor })

-- A window panel needs a claim when it holds none, or one that is dead or smaller than its texture.
function layer.needed(self: Claimant, pixelWidth: number, pixelHeight: number): boolean
  if self.kind ~= 'window' then
    return false
  end
  local claim = self.claim
  if not claim or claim.dead then
    return true
  end
  local layerWidth: number? = claim.width
  local layerHeight: number? = claim.height
  return not (layerWidth and layerHeight and pixelWidth <= layerWidth and pixelHeight <= layerHeight)
end

-- Releasing a claim returns a visible panel to scene drawing.
function layer.release(self: Claimant): ()
  local claim = self.claim
  self.claim = nil
  self.granted = false
  self.appliedViewport = nil
  if claim and not claim.dead then
    claim:release()
  end
end

function layer.acquire(self: Claimant, pixelWidth: number, pixelHeight: number): ()
  if self.kind ~= 'window' then
    return
  end
  layer.release(self)
  self.claim = lunette.claimLayer {
    window = self.source,
    width = pixelWidth,
    height = pixelHeight,
    priority = self.priority,
  }
end

-- Applies the current grant. `place` puts the held layer where the panel is; the viewport is set here.
function layer.drive(self: Claimant, viewport: Viewport, place: (Layer) -> ()): ()
  if not self.claim then
    return
  end

  local granted = self.claim.granted and true or false
  local applied = self.appliedViewport
  local changed = not applied
    or applied.x ~= viewport.x
    or applied.y ~= viewport.y
    or applied.width ~= viewport.width
    or applied.height ~= viewport.height
  if not granted then
    self.appliedViewport = nil
    self.granted = false
    return
  end

  local held = self.claim.layer
  if not held then
    return
  end

  if changed or not self.granted then
    held:setViewport(viewport.x, viewport.y, viewport.width, viewport.height)
    self.appliedViewport = viewport
  end

  place(held)

  self.granted = true
end

return layer
