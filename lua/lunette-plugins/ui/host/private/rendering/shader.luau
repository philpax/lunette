-- The toolkit shaders: instanced rounded boxes with sides, borders, edge bevels, and clipping, and clipped MSDF text.
-- Panel coordinates reach the shaders in metres from the top-left corner, with y down; the panel pose maps the
-- panel's centre to the world, with y up and z towards the viewer.

local shader = {}

-- Seven vec4 slots per box. 128 boxes fill 14336 bytes, inside the 16384-byte uniform range that Vulkan guarantees.
shader.SLOTS = 7
shader.BATCH = 128

-- A curved panel is a vertical cylinder of radius 1 / curve whose centre lies on the viewer's side; panel x is the
-- arc length from the panel's centre line, and elevation is along the cylinder's inward normal.
local BEND = [[
  uniform vec4 panelCurve;

  vec3 bend(float x, float y, float z) {
    float curve = panelCurve.x;
    if (curve <= 0.) {
      return vec3(x, y, z);
    }
    float radius = 1. / curve;
    float angle = x * curve;
    return vec3((radius - z) * sin(angle), y, radius - (radius - z) * cos(angle));
  }
]]

local COMMON = BEND
  .. [[
  uniform vec4 panelSize;
  uniform vec4 edgeLight;
  uniform vec4 edgeDark;
  // A scrim over a panel that a dialog blocks: an sRGB colour and how far every colour moves towards it.
  uniform vec4 panelScrim;

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
    // The grid template for curved panels spans the box in UV and is shaped by the fragment stage.
    vec2 p = panelCurve.y > .5 ? VertexUV * extent : VertexPosition.xy * (extent - r) + VertexUV * r;
    float z = shape.x - (1. - VertexPosition.z) * shape.y;
    // Rotation turns the box about its centre in the panel plane; the fragment stage shapes it unrotated.
    float angle = boxes[base + 6].y;
    vec2 turned = vec2(cos(angle) * p.x - sin(angle) * p.y, sin(angle) * p.x + cos(angle) * p.y);
    vec2 panel = rect.xy + extent + turned;
    boxLocal = p;
    boxPanel = panel;
    boxSide = 1. - abs(VertexNormal.z);
    boxIndex = InstanceIndex;
    vec3 local = bend(panel.x - panelSize.x * .5, panelSize.y * .5 - panel.y, z);
    return ClipFromLocal * vec4(local, 1.);
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
      // The grid template is rectangular, so the rounded corners are cut here.
      if (panelCurve.y > .5 && d > aa * .5) {
        discard;
      }
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
    color.rgb = mix(color.rgb, panelScrim.rgb, panelScrim.a);
    return vec4(gammaToLinear(color.rgb), color.a);
  }
]]

-- Image quads carry panel coordinates directly; the draw transform applies the panel pose and enclosing transforms.
shader.imageVertex = BEND
  .. [[
  uniform vec4 panelSize;
  uniform vec4 imageRect;
  uniform vec4 imageElevation;
  out vec2 imagePanel;

  vec4 lovrmain() {
    imagePanel = imageRect.xy + VertexUV * imageRect.zw;
    vec3 local = bend(imagePanel.x - panelSize.x * .5, panelSize.y * .5 - imagePanel.y, imageElevation.x);
    return ClipFromLocal * vec4(local, 1.);
  }
]]

-- Five vec4 slots per glyph: the quad's panel rectangle, its atlas rectangle, its colour, its clip, and its
-- elevation. 200 glyphs fill 16000 bytes, inside the 16384-byte uniform range that Vulkan guarantees.
shader.GLYPH_SLOTS = 5
shader.GLYPH_BATCH = 200

-- Instanced glyph quads from the native glyph atlas. Template vertices span 0 to 1 in x and y, y down.
shader.glyphVertex = BEND
  .. (
    string.gsub(
      [[
  uniform mat4 panelPose;
  uniform vec4 panelSize;

  uniform Glyphs {
    vec4 glyphs[GLYPH_VECTORS];
  };

  out vec2 glyphPanel;
  out vec2 glyphUV;
  out vec4 glyphColor;
  flat out vec4 glyphClip;

  vec4 lovrmain() {
    int base = InstanceIndex * 5;
    vec4 rect = glyphs[base];
    vec4 uv = glyphs[base + 1];
    glyphColor = glyphs[base + 2];
    glyphClip = glyphs[base + 3];
    float z = glyphs[base + 4].x;
    vec2 corner = VertexPosition.xy;
    vec2 panel = rect.xy + corner * rect.zw;
    glyphPanel = panel;
    glyphUV = mix(uv.xy, uv.zw, corner);
    vec3 bent = bend(panel.x - panelSize.x * .5, panelSize.y * .5 - panel.y, z);
    return ViewProjection * (panelPose * vec4(bent, 1.));
  }
]],
      'GLYPH_VECTORS',
      tostring(shader.GLYPH_SLOTS * shader.GLYPH_BATCH)
    )
  )

-- The field's range in texture coordinates sets the edge width from screen-space derivatives on each axis, so
-- edges stay antialiased at any distance and at grazing angles.
shader.glyphFragment = [[
  uniform vec4 glyphRange;
  uniform vec4 panelScrim;
  in vec2 glyphPanel;
  in vec2 glyphUV;
  in vec4 glyphColor;
  flat in vec4 glyphClip;

  float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
  }

  vec4 lovrmain() {
    if (glyphPanel.x < glyphClip.x || glyphPanel.y < glyphClip.y || glyphPanel.x > glyphClip.z || glyphPanel.y > glyphClip.w) {
      discard;
    }
    vec3 msdf = getPixel(ColorTexture, glyphUV).rgb;
    float sdf = median(msdf.r, msdf.g, msdf.b);
    vec2 screenTexSize = vec2(1.) / fwidth(glyphUV);
    float range = max(.5 * dot(glyphRange.xy, screenTexSize), 1.);
    float alpha = clamp(range * (sdf - .5) + .5, 0., 1.);
    if (alpha <= 0.) {
      discard;
    }
    // Instance colours are sRGB, as box colours are, and the pass blends in linear space.
    vec3 tinted = mix(glyphColor.rgb, panelScrim.rgb, panelScrim.a);
    return vec4(gammaToLinear(tinted), glyphColor.a * alpha);
  }
]]

-- Images sample their texture, multiplied by the draw colour, and clip in panel coordinates.
shader.imageFragment = [[
  uniform vec4 imageClip;
  uniform vec4 panelScrim;
  in vec2 imagePanel;

  vec4 lovrmain() {
    if (imagePanel.x < imageClip.x || imagePanel.y < imageClip.y || imagePanel.x > imageClip.z || imagePanel.y > imageClip.w) {
      discard;
    }
    vec4 color = Color * getPixel(ColorTexture, UV);
    if (color.a <= 0.) {
      discard;
    }
    // The draw colour and texture are linear here, so the scrim's sRGB colour is converted first.
    color.rgb = mix(color.rgb, gammaToLinear(panelScrim.rgb), panelScrim.a);
    return color;
  }
]]

return shader
