-- Shares curtain onset equations between analytic lighting and the longitude-altitude texture field.
local field = {}

field.equations = [[
  float zone(float v, float centre, float width) {
    float distance = (v - centre) / width;
    return exp(-distance * distance * 2.);
  }
  float ripple(float front, float width, float frequency) {
    return exp(-front * front * width) * (.55 + .45 * cos(front * frequency));
  }
  float bassPulse(float u, vec4 wave, vec4 prepared, float strength) {
    float detail = prepared.x;
    float width = mix(.85, 1.25, detail);
    float distance = ringDistance(u, wave.z);
    float front = distance - prepared.y;
    float pulse = strength * exp(-distance * distance * 650. * width) * prepared.w;
    pulse += strength * ripple(front, 380. * width, mix(75., 100., detail)) * prepared.z;
    return pulse;
  }
  float midPulse(float u, vec4 wave, vec4 prepared, float strength) {
    float detail = prepared.x;
    float width = mix(.85, 1.25, detail);
    float front = ringDistance(u, wave.z) - prepared.y;
    return strength * ripple(front, 950. * width, mix(120., 150., detail)) * prepared.z;
  }
  float treblePulse(float u, vec4 wave, vec4 prepared, float strength) {
    float width = mix(.85, 1.25, prepared.x);
    float distance = ringDistance(u, wave.z);
    // The envelope rises smoothly; fine rays shimmer spatially instead of flashing the whole curtain.
    return strength * exp(-distance * distance * 420. * width) * prepared.z;
  }
  vec2 bassWindow(vec4 wave, vec4 prepared) {
    return vec2(mix(.035, .14, prepared.x) + min(wave.x, .4) * .08, .13);
  }
  vec2 midWindow(vec4 prepared) {
    return vec2(mix(.26, .48, prepared.x), mix(.16, .11, prepared.x));
  }
  vec2 trebleWindow(vec4 prepared) {
    return vec2(mix(.58, .72, prepared.x), .16);
  }
]]

field.analytic = [[
    int count = clamp(backdropWaveCount, 0, WAVES);
    int bassEnd = clamp(int(backdropWaveEnds.x), 0, count);
    int midEnd = clamp(int(backdropWaveEnds.y), bassEnd, count);
    for (int i = 0; i < bassEnd; i++) {
      vec4 wave = backdropWaves[i];
      vec4 prepared = backdropWaveDetail[i];
      float pulse = bassPulse(u, wave, prepared, wave.y * onsetFocus(1., backdropFocus.xyz));
      vec2 window = bassWindow(wave, prepared);
      flash += pulse;
      flashZone += pulse * zone(v, window.x, window.y);
    }
    for (int i = bassEnd; i < midEnd; i++) {
      vec4 wave = backdropWaves[i];
      vec4 prepared = backdropWaveDetail[i];
      float pulse = midPulse(u, wave, prepared, wave.y * onsetFocus(2., backdropFocus.xyz));
      vec2 window = midWindow(prepared);
      crest += pulse;
      crestZone += pulse * zone(v, window.x, window.y);
    }
    for (int i = midEnd; i < count; i++) {
      vec4 wave = backdropWaves[i];
      vec4 prepared = backdropWaveDetail[i];
      float pulse = treblePulse(u, wave, prepared, wave.y * onsetFocus(3., backdropFocus.xyz));
      vec2 window = trebleWindow(prepared);
      surge += pulse;
      surgeZone += pulse * zone(v, window.x, window.y);
    }
]]

field.bindings = [[
  uniform texture2D onsetPulses;
  uniform texture2D onsetZones;
  uniform sampler onsetSampler;
]]

field.cached = [[
    if (backdropWaveCount > 8) {
      vec2 onsetUV = vec2(fract(u), clamp(v, 0., 1.));
      vec3 focus = vec3(onsetFocus(1., backdropFocus.xyz), onsetFocus(2., backdropFocus.xyz),
        onsetFocus(3., backdropFocus.xyz));
      vec3 pulses = textureLod(sampler2D(onsetPulses, onsetSampler), vec2(onsetUV.x, .5), 0.).rgb * focus;
      vec3 zones = textureLod(sampler2D(onsetZones, onsetSampler), onsetUV, 0.).rgb * focus;
      flash = pulses.r;
      crest = pulses.g;
      surge = pulses.b;
      flashZone = zones.r;
      crestZone = zones.g;
      surgeZone = zones.b;
    } else {
]] .. field.analytic .. [[
    }
]]

field.compute = [[
  layout(local_size_x = 8, local_size_y = 8) in;
  layout(rgba16f) uniform writeonly image2D onsetPulsesImage;
  layout(rgba16f) uniform writeonly image2D onsetZonesImage;
  uniform vec4 backdropWaveEnds;
]] .. field.equations .. [[
  shared vec4 onsetWaveTerms[8 * WAVES];

  void lovrmain() {
    int column = int(GlobalThreadID.x);
    int row = int(GlobalThreadID.y);
    ivec2 size = imageSize(onsetZonesImage);
    int termBase = int(gl_LocalInvocationID.x) * WAVES;
    int count = clamp(backdropWaveCount, 0, WAVES);
    int bassEnd = clamp(int(backdropWaveEnds.x), 0, count);
    int midEnd = clamp(int(backdropWaveEnds.y), bassEnd, count);
    if (gl_LocalInvocationID.y == 0u && column < size.x) {
      float u = (float(column) + .5) / float(size.x);
      vec3 pulses = vec3(0.);
      for (int i = 0; i < bassEnd; i++) {
        vec4 wave = backdropWaves[i];
        vec4 prepared = backdropWaveDetail[i];
        float pulse = bassPulse(u, wave, prepared, wave.y);
        onsetWaveTerms[termBase + i] = vec4(pulse, bassWindow(wave, prepared), 0.);
        pulses.r += pulse;
      }
      for (int i = bassEnd; i < midEnd; i++) {
        vec4 wave = backdropWaves[i];
        vec4 prepared = backdropWaveDetail[i];
        float pulse = midPulse(u, wave, prepared, wave.y);
        onsetWaveTerms[termBase + i] = vec4(pulse, midWindow(prepared), 0.);
        pulses.g += pulse;
      }
      for (int i = midEnd; i < count; i++) {
        vec4 wave = backdropWaves[i];
        vec4 prepared = backdropWaveDetail[i];
        float pulse = treblePulse(u, wave, prepared, wave.y);
        onsetWaveTerms[termBase + i] = vec4(pulse, trebleWindow(prepared), 0.);
        pulses.b += pulse;
      }
      // Only the first altitude tile writes the height-one pulse texture.
      if (row == 0) imageStore(onsetPulsesImage, ivec2(column, 0), vec4(pulses, 0.));
    }
    // Edge lanes must reach the barrier before leaving the workgroup.
    barrier();
    if (column >= size.x || row >= size.y) return;
    float v = (float(row) + .5) / float(size.y);
    vec3 zones = vec3(0.);
    for (int i = 0; i < bassEnd; i++) {
      vec4 term = onsetWaveTerms[termBase + i];
      zones.r += term.x * zone(v, term.y, term.z);
    }
    for (int i = bassEnd; i < midEnd; i++) {
      vec4 term = onsetWaveTerms[termBase + i];
      zones.g += term.x * zone(v, term.y, term.z);
    }
    for (int i = midEnd; i < count; i++) {
      vec4 term = onsetWaveTerms[termBase + i];
      zones.b += term.x * zone(v, term.y, term.z);
    }
    imageStore(onsetZonesImage, ivec2(column, row), vec4(zones, 0.));
  }
]]

return field
