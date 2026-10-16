-- The toolkit shaders: instanced rounded boxes with sides, borders, edge bevels, and clipping, and clipped MSDF text.
-- Panel coordinates reach the shaders in metres from the top-left corner, with y down; the panel pose maps the
-- panel's centre to the world, with y up and z towards the viewer.

local shader = {}

-- Seven vec4 slots per box. 128 boxes fill 14336 bytes, inside the 16384-byte uniform range that Vulkan guarantees.
shader.SLOTS = 7
shader.BATCH = 128

local COMMON = [[
  uniform vec4 panelSize;
  uniform vec4 edgeLight;
  uniform vec4 edgeDark;

  uniform Boxes {
    vec4 boxes[BOX_VECTORS];
  };

  // Negative inside a rectangle of half extents `extent` with corner radius `r`, centred on the origin.
  float roundedBox(vec2 p, vec2 extent, float r) {
    vec2 q = abs(p) - extent + r;
    return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r;
  }
]]

local function substitute(source: string): string
  return (string.gsub(COMMON .. source, 'BOX_VECTORS', tostring(shader.SLOTS * shader.BATCH)))
end

-- Template vertices: position.xy is the corner's sign, position.z is 1 on the top face and 0 at the bottom of a
-- side, and UV is the rounding direction from the corner's centre. A side vertex has a normal with no z.
shader.boxVertex = substitute [[
  out vec2 boxLocal;
  out vec2 boxPanel;
  out float boxSide;
  flat out int boxIndex;

  vec4 lovrmain() {
    int base = InstanceIndex * 7;
    vec4 rect = boxes[base];
    vec4 shape = boxes[base + 1];
    vec2 extent = rect.zw * .5;
    float r = min(shape.z, min(extent.x, extent.y));
    vec2 p = VertexPosition.xy * (extent - r) + VertexUV * r;
    float z = shape.x - (1. - VertexPosition.z) * shape.y;
    // Rotation turns the box about its centre in the panel plane; the fragment stage shapes it unrotated.
    float angle = boxes[base + 6].y;
    vec2 turned = vec2(cos(angle) * p.x - sin(angle) * p.y, sin(angle) * p.x + cos(angle) * p.y);
    vec2 panel = rect.xy + extent + turned;
    boxLocal = p;
    boxPanel = panel;
    boxSide = 1. - abs(VertexNormal.z);
    boxIndex = InstanceIndex;
    vec4 local = vec4(panel.x - panelSize.x * .5, panelSize.y * .5 - panel.y, z, 1.);
    return ClipFromLocal * local;
  }
]]

shader.boxFragment = substitute [[
  in vec2 boxLocal;
  in vec2 boxPanel;
  in float boxSide;
  flat in int boxIndex;

  vec4 lovrmain() {
    int base = boxIndex * 7;
    vec4 rect = boxes[base];
    vec4 shape = boxes[base + 1];
    vec4 clip = boxes[base + 5];
    vec4 flags = boxes[base + 6];
    if (boxPanel.x < clip.x || boxPanel.y < clip.y || boxPanel.x > clip.z || boxPanel.y > clip.w) {
      discard;
    }
    vec4 color;
    if (boxSide > .5) {
      color = boxes[base + 4];
    } else {
      vec2 extent = rect.zw * .5;
      float r = min(shape.z, min(extent.x, extent.y));
      float d = roundedBox(boxLocal, extent, r);
      float aa = max(fwidth(d), 1e-6);
      color = boxes[base + 2];
      if (shape.w > 0.) {
        vec4 border = boxes[base + 3];
        float t = clamp((d + shape.w) / aa + .5, 0., 1.);
        color = mix(color, vec4(border.rgb, 1.), t * border.a);
      }
      if (flags.x > 0.) {
        // The light edge runs along the top of the face and the dark edge along the bottom, as on a key lit from
        // above. Panel y grows downward, so the top edge has negative local y.
        float edge = clamp((d + flags.x) / aa + .5, 0., 1.);
        vec2 q = abs(boxLocal) - extent + r;
        vec2 outward = q.x > 0. && q.y > 0. ? normalize(q) * sign(boxLocal) : (q.x > q.y ? vec2(sign(boxLocal.x), 0.) : vec2(0., sign(boxLocal.y)));
        float light = clamp(-outward.y, 0., 1.);
        float dark = clamp(outward.y, 0., 1.);
        color.rgb = mix(color.rgb, edgeLight.rgb, edge * light * edgeLight.a);
        color.rgb = mix(color.rgb, edgeDark.rgb, edge * dark * edgeDark.a);
      }
    }
    if (color.a <= 0.) {
      discard;
    }
    return vec4(gammaToLinear(color.rgb), color.a);
  }
]]

-- Text keeps LÖVR's own glyph vertices and transform; the fragment stage clips in panel coordinates.
shader.textVertex = [[
  uniform mat4 panelInverse;
  uniform vec4 panelSize;
  out vec2 textPanel;

  vec4 lovrmain() {
    vec4 world = Transform * VertexPosition;
    vec4 local = panelInverse * world;
    textPanel = vec2(local.x + panelSize.x * .5, panelSize.y * .5 - local.y);
    return DefaultPosition;
  }
]]

shader.textFragment = [[
  uniform vec4 textClip;
  in vec2 textPanel;

  float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
  }

  vec4 lovrmain() {
    if (textPanel.x < textClip.x || textPanel.y < textClip.y || textPanel.x > textClip.z || textPanel.y > textClip.w) {
      discard;
    }
    vec3 msdf = getPixel(ColorTexture, UV).rgb;
    float sdf = median(msdf.r, msdf.g, msdf.b);
    vec2 screenTexSize = vec2(1.) / fwidth(UV);
    float range = max(.5 * dot(Material.sdfRange, screenTexSize), 1.);
    float alpha = clamp(range * (sdf - .5) + .5, 0., 1.);
    if (alpha <= 0.) {
      discard;
    }
    return vec4(Color.rgb, Color.a * alpha);
  }
]]

return shader
