-- Monochrome icons for the standard kinds. Each is an SVG source whose white shapes the button's ink tints. A lock
-- icon pairs a content or transform glyph with a lock badge, drawn as paths because the rasteriser draws no text.

local uiHost = require '@lunette-contracts/ui-host'

local icons = {}

local GEAR =
  '<path d="M19.14 12.94c.04-.3.06-.61.06-.94s-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/>'

-- A lock badge in the top-right corner. The primary glyph leaves it clear, so one ink reads both shapes.
local LOCK_BADGE = '<path d="M16 6.6V5a2.2 2.2 0 0 1 4.4 0V6.6h-1.6V5a0.8 0.8 0 0 0-1.6 0V6.6z'
  .. 'M14.8 6.6h7a1.4 1.4 0 0 1 1.4 1.4v3.2a1.4 1.4 0 0 1-1.4 1.4h-7a1.4 1.4 0 0 1-1.4-1.4V8a1.4 1.4 0 0 1 1.4-1.4z"/>'

-- A pointer arrow for content input, with the lock badge clear of its upper right.
local INPUT_GLYPH = '<path d="M2 4v15.2l3.8-3.8 2.2 5.4 2.4-1-2.2-5.4h4.6z"/>'

-- A four-way move gizmo for transform, with the lock badge clear of its right arm.
local TRANSFORM_GLYPH = '<path d="M5.5 4h2v16h-2z'
  .. 'M6.5 1.5 9.3 4.5H3.7zM6.5 22.5 3.7 19.5h5.6z'
  .. 'M2 10.5h9v2H2zM1 11.5 4 8.7v5.6zM12 11.5 9 8.7v5.6z"/>'

local function document(content: string): uiHost.ImageSource
  return {
    kind = 'svg',
    data = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
      .. '<g fill="#ffffff">'
      .. content
      .. '</g></svg>',
  }
end

icons.gear = document(GEAR)
icons.inputLock = document(INPUT_GLYPH .. LOCK_BADGE)
icons.transformLock = document(TRANSFORM_GLYPH .. LOCK_BADGE)

return icons
