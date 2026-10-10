-- Shaders that draw a client's pixels. Wayland buffers hold premultiplied sRGB, and an opaque buffer's fourth
-- component is padding, so each kind of buffer has its own conversion.

local plugin = require '@lunette-plugin'

local clientPixels = {}

local OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    vec3 linear = gammaToLinear(getPixel(ColorTexture, UV).rgb);
    return vec4(linear * Color.rgb * Color.a, Color.a);
  }
]]
local ALPHA_FRAGMENT = [[
  vec4 lovrmain() {
    vec4 pixel = getPixel(ColorTexture, UV);
    if (pixel.a <= 0.) return vec4(0.);
    vec3 linear = gammaToLinear(clamp(pixel.rgb / pixel.a, 0., 1.));
    float alpha = pixel.a * Color.a;
    return vec4(linear * Color.rgb * alpha, alpha);
  }
]]

-- `choose(opaque)` answers nil once `live` answers false or the context has ended. `held(opaque)` reports whether
-- that shader exists.
export type Shaders = {
  read choose: (opaque: boolean) -> Shader?,
  read held: (opaque: boolean) -> boolean,
}

-- Each shader is made on first use and released with the context. Blend the result with
-- `setBlendMode('alpha', 'premultiplied')`.
function clientPixels.shaders(context: plugin.Context, live: () -> boolean): Shaders
  local made: { [boolean]: Shader } = {}
  local function choose(given: boolean): Shader?
    -- A table key cannot be nil, and a source that reports no opacity is drawn with its alpha.
    local opaque = given == true
    if not live() or not context:active() then
      return nil
    end
    local cached = made[opaque]
    if cached then
      return cached
    end
    context:effect(function()
      local shader = lovr.graphics.newShader('unlit', if opaque then OPAQUE_FRAGMENT else ALPHA_FRAGMENT)
      made[opaque] = shader
      return function()
        shader:release()
        made[opaque] = nil
      end
    end)
    return made[opaque]
  end
  return table.freeze {
    choose = choose,
    held = function(opaque: boolean): boolean
      return made[opaque == true] ~= nil
    end,
  }
end

return clientPixels
