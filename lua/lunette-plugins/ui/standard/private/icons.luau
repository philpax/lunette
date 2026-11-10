-- Monochrome icons for the standard kinds. Each is an SVG source whose white shapes the button's ink tints. The
-- letters in the lock icons are paths, because the rasteriser draws no text elements.

local uiHost = require '@lunette-contracts/ui-host'

local icons = {}

local GEAR =
  '<path d="M19.14 12.94c.04-.3.06-.61.06-.94s-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/>'

-- The shackle and body, with the state letter cut out as a hole by the even-odd rule.
local SHACKLE = 'M8 10V7a4 4 0 0 1 8 0v3h-2V7a2 2 0 0 0-4 0v3z'
local BODY = 'M5 10h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z'
local INPUT_LETTER = 'M11 12.2h2v6.6h-2zM9.4 12.2h5.2v1.5H9.4zM9.4 17.4h5.2v1.4H9.4z'
local TRANSFORM_LETTER = 'M9.2 12.2h5.6v1.5H9.2zM10.8 12.2h2.4v6.6h-2.4z'

local function lock(letter: string): string
  return '<path fill-rule="evenodd" d="' .. SHACKLE .. BODY .. letter .. '"/>'
end

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
icons.inputLock = document(lock(INPUT_LETTER))
icons.transformLock = document(lock(TRANSFORM_LETTER))

return icons
