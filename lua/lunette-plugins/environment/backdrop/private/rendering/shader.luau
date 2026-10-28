-- Cached overhead light, analytic sky diagnostics, and emissive curtains with fixed onset positions.
local model = require './model'
local overheadField = require './overhead-field'
local onsetField = require './onset-field'

local shader = {}

-- Waves arrive as (age, faded strength, longitude, band), with band 1 bass, 2 mid, and 3 treble. Live waves fill the
-- first `backdropWaveCount` slots, grouped stably by band. The cumulative ends bound the curtain's band loops.
local WAVES = [[
  const int WAVES = WAVE_COUNT;
  uniform vec4 backdropWaves[WAVES];
  // Frequency detail, travelled distance, band decay (including treble rise), and initial bass decay.
  uniform vec4 backdropWaveDetail[WAVES];
  uniform int backdropWaveCount;

  float ringDistance(float u, float position) {
    return abs(fract(u - position + .5) - .5);
  }

  // Loudness widens the drifting arcs but leaves their darkest gaps open even at full energy.
  float ribbon(float phase, float layer, float time, float level) {
    float wander = sin(phase * 2. + layer * 2.1 + time * 52.) * .6 + sin(phase * 3. - layer * 1.3 - time * 38.) * .4;
    float open = clamp(level, 0., 1.);
    return smoothstep(-.48 - open * .08, .32 - open * .1, wander);
  }

  float onsetFocus(float band, vec3 focus) {
    float own = band < 1.5 ? focus.x : band < 2.5 ? focus.y : focus.z;
    return pow(clamp(own / 1.6, 0., 1.), 2.);
  }
]]

-- Autonomous terms take time in radians per 4096 units of model time, which advances at the motion strength
-- in units per second. Their multipliers are whole numbers so every term is continuous where the clock wraps;
-- a multiplier of 140 completes a cycle in about 29 seconds at full motion.

local function withWaves(source: string): string
  local waves = string.gsub(WAVES, 'WAVE_COUNT', tostring(model.MAX_WAVES))
  return waves .. source
end

local SPECTRUM = [[
  uniform vec4 backdropSpectrum[2];
  uniform vec4 backdropStereo[2];
  uniform vec4 backdropFacing;

  // Increasing longitude from forward goes left; a positive channel difference goes right.
  float stereoSide(float u) {
    return -sin(TAU * (u - backdropFacing.x));
  }
  float spectrum(int index, float side) {
    int group = index / 4;
    int lane = index - group * 4;
    float combined = backdropSpectrum[group][lane];
    float stereo = backdropStereo[group][lane];
    return max(0., combined + stereo * side);
  }
]]

shader.skyVertex = [[
  out vec3 skyDirection;

  vec4 lovrmain() {
    skyDirection = VertexPosition.xyz;
    return DefaultPosition;
  }
]]
local SKY = [[
  uniform vec4 backdropSky;
  uniform vec4 backdropResponse;
  uniform vec3 backdropZenith;
  uniform vec3 backdropHorizon;
  uniform vec3 backdropGlint;
  uniform vec3 backdropTreble;
  uniform vec3 backdropMid;

  in vec3 skyDirection;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
]] .. overheadField .. [[
  vec3 overhead(vec3 direction, float time, float energy, out vec2 projected, out vec2 field, out float density) {
    // The overhead field is absent below the horizon, where the nadir projection is singular.
    if (direction.y <= 0.) {
      projected = vec2(0.);
      field = vec2(0.);
      density = 0.;
      return vec3(0.);
    }
    // Stereographic coordinates from the nadir have no seam at the zenith.
    vec2 q = direction.xz / (1. + direction.y) * 3.;
    projected = q;
    return overheadAt(q, time, energy, field, density);
  }
#ifdef BACKDROP_CACHED_OVERHEAD
  uniform texture2D overheadTexture;
  uniform sampler overheadSampler;

  vec3 overheadCached(vec3 direction) {
    if (direction.y <= 0.) return vec3(0.);
    vec2 q = direction.xz / (1. + direction.y) * 3.;
    vec2 uv = q / 6. + .5;
    return textureLod(sampler2D(overheadTexture, overheadSampler), uv, 0.).rgb;
  }
#endif
  vec4 lovrmain() {
    float height = sin((UV.y - .5) * 3.14159265);
    float up = smoothstep(0., .85, height);
    vec3 sky = mix(backdropHorizon, backdropZenith, up);
    sky *= mix(.18, 1., smoothstep(-.2, .12, height));
    float above = smoothstep(.05, .5, height);
    if (above > 0.) {
      vec2 cell = floor(UV * vec2(360., 180.));
      float seed = hash(cell);
      // Even the strongest treble onset only lights seeds at or above .994.
      if (seed >= .998 - .004) {
        vec2 point = fract(UV * vec2(360., 180.)) - .5;
        float shape = 1. - smoothstep(.015, .08, length(point));
        if (shape > 0.) {
          float burst = 0.;
          for (int i = 0; i < min(backdropWaveCount, WAVES); i++) {
            vec4 wave = backdropWaves[i];
            if (wave.w > 2.5) {
              float distance = ringDistance(UV.x, wave.z);
              burst += wave.y * exp(-distance * distance * 300.);
            }
          }
          float star = step(.998, seed) * shape;
          // A treble burst adds stars of its own and lights them only in the treble hue.
          float extra = step(.998 - .004 * min(burst, 1.), seed) * shape;
          float rate = .0092038847 * (1. + backdropResponse.z * 3.);
          float twinkle = .6 + .4 * sin(backdropSky.y * rate + seed * 6.2831853);
          sky += backdropGlint * star * twinkle * above * .13;
          sky += backdropTreble * extra * twinkle * above * min(burst, 1.) * .6;
        }
      }
    }
    // The curtains' light spills into the low sky as a faint airglow that swells with the mid band.
    float airglow = exp(-abs(height - .3) * 6.) * smoothstep(.08, .2, height);
    sky += backdropMid * airglow * (.005 + .015 * backdropResponse.y);
    // The direction comes from the interpolated position, not from UV. Near the zenith one triangle spans a wide
    // range of longitude, and UV interpolated across it bends the field into visible facets at every edge.
    vec3 direction = normalize(skyDirection);
    float energy = dot(backdropResponse.xyz, vec3(1. / 3.));
    float time = backdropSky.y * (TAU / 4096.);
    int view = int(backdropSky.w + .5);
    if (view == 1) return vec4(direction * .5 + .5, 1.);
    float fieldMask = smoothstep(.3, .65, height);
    vec2 projected = vec2(0.);
    vec2 warped = vec2(0.);
    float density = 0.;
    vec3 patches = vec3(0.);
    // Diagnostics inspect the unmasked field; normal rendering needs it only where it contributes light.
#ifdef BACKDROP_CACHED_OVERHEAD
    if (view != 0) {
      patches = overhead(direction, time, energy, projected, warped, density);
    } else if (fieldMask > 0. && backdropSky.z > 0.) {
      patches = overheadCached(direction);
    }
#else
    if (view != 0 || (fieldMask > 0. && backdropSky.z > 0.)) {
      patches = overhead(direction, time, energy, projected, warped, density);
    }
#endif
    if (view == 2) {
      return vec4(fract(projected), 0., 1.);
    } else if (view == 3) {
      ivec2 cell = ivec2(floor(warped * vec2(1.6, 3.)));
      return vec4(lattice(cell), lattice(cell + ivec2(7, 3)), lattice(cell + ivec2(2, 9)), 1.);
    } else if (view == 4) {
      return vec4(vec3(density), 1.);
    } else if (view == 5) {
      return vec4(patches * 6., 1.);
    }
    vec3 field = patches * fieldMask * backdropSky.z;
    float alpha = clamp(backdropSky.x, 0., 1.);
    return vec4((clamp(sky * backdropSky.z, 0., .12) + min(field, vec3(.35))) * alpha, alpha);
  }
]]
shader.skyFragment = withWaves(SKY)
shader.skyCachedFragment = withWaves('#define BACKDROP_CACHED_OVERHEAD\n' .. SKY)
shader.skyCompute = [[
  layout(local_size_x = 8, local_size_y = 8) in;
  layout(rgba16f) uniform writeonly image2D overheadImage;
  uniform vec4 backdropResponse;
  uniform vec4 backdropSky;
  uniform vec3 backdropMid;
  uniform vec3 backdropTreble;
]] .. overheadField .. [[
  void lovrmain() {
    ivec2 pixel = ivec2(GlobalThreadID.xy);
    ivec2 size = imageSize(overheadImage);
    if (any(greaterThanEqual(pixel, size))) return;
    vec2 uv = (vec2(pixel) + .5) / vec2(size);
    // The whole square leaves a filtering margin outside the visible upper-hemisphere disk.
    vec2 q = (uv * 2. - 1.) * 3.;
    float energy = dot(backdropResponse.xyz, vec3(1. / 3.));
    float time = backdropSky.y * (TAU / 4096.);
    vec2 field;
    float density;
    imageStore(overheadImage, pixel, vec4(overheadAt(q, time, energy, field, density), 1.));
  }
]]
shader.curtainVertex = withWaves(SPECTRUM .. [[
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;
  uniform vec4 backdropFocus;

  vec4 lovrmain() {
    float u = VertexUV.x;
    float v = VertexUV.y;
    float layer = backdropScene.z;
    float time = backdropScene.y * (TAU / 4096.);
    float angle = TAU * u;
    float phase = angle + layer * 1.8;
    float levels[8];
    float side = stereoSide(u);
    float energy = 0.;
    for (int i = 0; i < 8; i++) {
      levels[i] = spectrum(i, side);
      energy += levels[i] / 8.;
    }
    float own = layer < .5 ? max(max(levels[0], levels[1]), levels[2])
      : layer < 1.5 ? max(max(levels[3], levels[4]), levels[5]) : max(levels[6], levels[7]);
    float fold = sin(phase * 5. + time * 140.) + .45 * sin(phase * 11. - time * 98.);
    float heave = 0.;
    float ripple = 0.;
    float lift = 0.;
    float surge = 0.;
    for (int i = 0; i < min(backdropWaveCount, WAVES); i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(u, wave.z);
      vec4 prepared = backdropWaveDetail[i];
      float detail = prepared.x;
      float strength = wave.y * onsetFocus(wave.w, backdropFocus.xyz);
      float width = mix(.85, 1.25, detail);
      if (wave.w < 1.5) {
        float front = distance - prepared.y;
        heave += strength * exp(-front * front * 220. * width) * prepared.z;
      } else if (wave.w < 2.5) {
        float front = distance - prepared.y;
        ripple += strength * exp(-front * front * 1100. * width) * sin(front * 100.);
        lift += strength * exp(-front * front * 650. * width) * prepared.z;
      } else {
        surge += strength * exp(-distance * distance * 420. * width) * prepared.z;
      }
    }
    heave = min(heave, 1.5);
    // Onsets can briefly raise an arc in a gap without making sustained energy fill the ring.
    float reach = max(ribbon(phase, layer, time, own), min(heave + lift + surge, .8));
    float swell = levels[0] * sin(phase * 2. + time * 42.) * .04;
    swell += levels[1] * sin(phase * 4. - time * 70.) * .027;
    float rolls = levels[2] * sin(phase * 7. + time * 98.) * exp(-v * 5.) * .025;
    float folds = levels[3] * sin(phase * 9. + time * 140.) * .025;
    folds += levels[4] * sin(phase * 13. - time * 175. + v * 5.) * .022;
    folds += levels[5] * sin(phase * 19. + time * 210.) * .016;
    // Fine treble texture stays in the fragment shader so low-quality meshes do not alias its rays.
    float tips = v * v * (levels[6] * sin(phase * 23. + time * 245.) * .012
      + levels[7] * sin(phase * 29. - time * 315.) * .008);
    float tilt = sin(angle + layer * 2.4 + time * 32.) * .06;
    float elevation = .15 + layer * .07 + tilt + sin(phase * 2. + time * 70.) * .035 + swell;
    float height = (.38 + .16 * energy + max(levels[6], levels[7]) * .02
      + heave * .06 + min(surge, 1.) * .035) * (.5 + .5 * reach);
    elevation += v * height + fold * .025 + rolls + folds + tips;
    elevation += ripple * .022 + v * min(lift, 1.) * .06;
    // In plan view each curtain meanders toward and away from the viewer in broad folds, so the curtains overlap
    // in depth and perspective makes the nearer stretches tower over the farther ones.
    float meander = sin(angle * 2. + layer * 2.1 + time * 42.) * .2 + sin(angle * 5. - layer * 1.4 + time * 91.) * .07;
    float radius = backdropScene.w * (1. + meander - layer * .05);
    // Folds swing the curtain several metres toward and away from the viewer as they travel along it.
    radius += fold * 1.8 + folds * 32. + heave * 1.1;
    vec3 position = vec3(sin(angle) * cos(elevation), sin(elevation), cos(angle) * cos(elevation)) * radius;
    return ClipFromLocal * vec4(position, 1.);
  }
]])
local function curtainFragment(onsets: string, bindings: string): string
  return withWaves(SPECTRUM .. bindings .. [[
  uniform vec4 backdropWaveEnds;
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;
  uniform vec4 backdropFocus;
  uniform vec3 backdropLow;
  uniform vec3 backdropHigh;
  uniform vec3 backdropBass;
  uniform vec3 backdropMid;
  uniform vec3 backdropTreble;

]] .. onsetField.equations .. [[
  vec4 lovrmain() {
    float u = UV.x;
    float v = UV.y;
    float visibility = backdropScene.x;
    if (visibility <= 0. || backdropResponse.w <= 0. || v <= 0.) return vec4(0.);
    float time = backdropScene.y * (6.28318530718 / 4096.);
    float layer = backdropScene.z;
    float phase = u * 6.28318530718 + layer * 1.8;
    float levels[8];
    float drive[8];
    float side = stereoSide(u);
    for (int i = 0; i < 8; i++) {
      levels[i] = spectrum(i, side);
      // Retain quiet detail at the mapped half-scale without raising the full-scale lighting budget.
      drive[i] = levels[i] * (.5 + .5 * levels[i]);
    }
    float own = layer < .5 ? max(max(levels[0], levels[1]), levels[2])
      : layer < 1.5 ? max(max(levels[3], levels[4]), levels[5]) : max(levels[6], levels[7]);

    // Rays lean and wander as they rise, so they read as light streaming along field lines rather than as
    // straight bars.
    float lean = v * (.08 * sin(phase * 3. + time * 70.) + .04 * sin(phase * 7. - time * 105.));
    float q = phase + lean;
    float r1 = .5 + .5 * sin(q * 43. + sin(q * 7. - time * 105.) * 2.);
    float r2 = .5 + .5 * sin(q * 89. + time * 175.);
    float r3 = .5 + .5 * sin(q * 157. - time * 245.);
    // Soft, uneven rays. Squares sharpen the sines a little without cutting dark gaps between them.
    float rays = r1 * r1 * .5 + r2 * r2 * .3 + .1 * r3 * r3;
    // Brightness streams up each ray, so no ray is a uniform pillar and the curtain seems to flow upward.
    float streak = .75 + .25 * sin(v * 7. + r1 * 3. - time * 525.);
    float folds = .6 + .4 * sin(phase * 5. + time * 140.);
    // Ray tops reach different heights along the curtain.
    float tops = .7 + .2 * sin(phase * 9. + time * 88.) + .1 * sin(phase * 23. - time * 122.);

    float flash = 0.;
    float crest = 0.;
    float surge = 0.;
    float flashZone = 0.;
    float crestZone = 0.;
    float surgeZone = 0.;
]] .. onsets .. [[
    flash = min(flash, 1.5);
    crest = min(crest, 1.5);
    surge = min(surge, 1.5);

    float hem = smoothstep(0., .03, v);
    float reachTop = min(tops + .12 + surge * .18, 1.);
    float fade = 1. - smoothstep(reachTop * .55, reachTop, v);
    float body = smoothstep(0., .06, v) * exp(-v * 2.2);
    float high = smoothstep(.25, .6, v) * (1. - smoothstep(.7, 1., v));
    vec3 light = backdropBass * exp(-v * 14.) * .35 + backdropLow * .75 * body + backdropHigh * .4 * high;
    light *= 1. - smoothstep(tops * .25, tops, v);
    vec3 responseLight = vec3(0.);

    // Separate altitude windows and spatial scales preserve all eight inputs, including adjacent sub-bands.
    float swell = .72 + .28 * sin(phase * 2. + time * 42.);
    float roll = .65 + .35 * sin(phase * 4. - time * 70. + v * 8.);
    float lowFold = .55 + .45 * sin(q * 7. + time * 98. + v * 12.);
    float ribbons = .5 + .5 * sin(q * 11. - time * 140. + v * 18.);
    float weave = .45 + .55 * pow(.5 + .5 * sin(q * 17. + time * 175. - v * 13.), 2.);
    float flare = .25 + .75 * pow(.5 + .5 * sin(q * 29. - time * 210. + v * 6.), 4.);
    float fine = .35 + .65 * r2 * r2;
    float glint = .15 + .85 * pow(r3, 4.);
    responseLight += backdropBass * (drive[0] * zone(v, .015, .07) * swell * 1.6
      + drive[1] * zone(v, .085, .08) * roll * 1.3 + drive[2] * zone(v, .17, .10) * lowFold * 1.1);
    responseLight += backdropMid * (drive[3] * zone(v, .27, .13) * ribbons * 1.25
      + drive[4] * zone(v, .39, .13) * weave * 1.3 + drive[5] * zone(v, .51, .12) * flare * 1.6);
    responseLight += backdropTreble * (drive[6] * zone(v, .61, .15) * fine * 1.6
      + drive[7] * zone(v, .72, .16) * glint * 2.);
    responseLight += backdropBass * min(flashZone, 1.5) * 3.;
    responseLight += mix(backdropMid, vec3(1.), .2) * min(crestZone, 1.5) * 2.2;
    responseLight += backdropTreble * min(surgeZone, 1.5) * 2. * (.4 + r3 * r3);
    light += responseLight * fade;
    float extent = max(ribbon(phase, layer, time, own), min(flash + crest + surge, .8));
    light *= hem * (.4 + .6 * rays) * streak * folds * extent * backdropResponse.w * .7;

    // The light is emitted rather than painted: alpha stays below the colour so overlapping curtains add up and
    // glow, while still dimming the stars behind them a little.
    float peak = max(max(light.r, light.g), light.b);
    // Scaling by the brightest channel limits the colour without bleaching it; what exceeds the bound turns a
    // little toward white, so the hottest cores glow instead of clipping into flat colour.
    float over = max(peak - .9, 0.);
    light *= min(1., .9 / max(peak, .0001));
    light += vec3(min(over, 1.) * .1);
    float alpha = clamp(peak * .2, 0., .2);
    return vec4(light, alpha) * clamp(visibility, 0., 1.);
  }
]])
end

shader.curtainFragment = curtainFragment(onsetField.analytic, '')
shader.curtainCachedFragment = curtainFragment(onsetField.cached, onsetField.bindings)
shader.curtainCompute = withWaves(onsetField.compute)

shader.wispVertex = withWaves [[
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;
  uniform vec3 backdropLow;
  uniform vec3 backdropHigh;
  uniform vec3 backdropMid;
  uniform vec3 backdropTreble;

  out vec3 wispColor;
  out float wispSeed;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  vec4 lovrmain() {
    float id = VertexNormal.x;
    float time = backdropScene.y * (TAU / 4096.);
    float energy = dot(backdropResponse.xyz, vec3(1. / 3.));
    // A fragment lives for 4096 / rate units of model time, about 9 to 15 seconds at full motion. The
    // whole-number rate keeps its phase continuous where the clock wraps, and folding the cycle count by the
    // rate keeps its seed continuous there too.
    float rate = floor(270. + 180. * hash(vec2(id, 1.)));
    float cycles = backdropScene.y * rate / 4096. + hash(vec2(id, 2.));
    float cycle = mod(floor(cycles), rate);
    float life = fract(cycles);
    float layer = floor(hash(vec2(id, cycle + 3.)) * 3.);
    float u = hash(vec2(id, cycle + 4.));
    float v = .15 + .5 * hash(vec2(id, cycle + 5.));
    // Louder music sets more fragments loose; the rest stay dark and collapse to a point.
    float loose = step(hash(vec2(id, cycle + 6.)), .3 + .7 * energy);
    float fade = smoothstep(0., .2, life) * (1. - smoothstep(.45, 1., life)) * loose;
    // A fragment leaves its curtain where it spawned, then rises, drifts sideways, and moves away as it fades.
    float angle = TAU * (u + (hash(vec2(id, cycle + 7.)) - .5) * .025 * life);
    float phase = angle + layer * 1.8;
    float tilt = sin(angle + layer * 2.4 + time * 32.) * .06;
    float elevation = .15 + layer * .07 + tilt + v * .45 + life * (.08 + .06 * hash(vec2(id, cycle + 8.)));
    float meander = sin(angle * 2. + layer * 2.1 + time * 42.) * .2 + sin(angle * 5. - layer * 1.4 + time * 91.) * .07;
    float radius = backdropScene.w * (1. + meander - layer * .05) * (1. + life * .08);
    vec3 centre = vec3(sin(angle) * cos(elevation), sin(elevation), cos(angle) * cos(elevation)) * radius;
    // The quad faces the head at the origin and stretches along the local vertical, like a loose ray.
    vec3 toward = normalize(centre);
    vec3 side = normalize(cross(vec3(0., 1., 0.), toward));
    vec3 up = cross(toward, side);
    float scale = radius / 25. * (.6 + .8 * hash(vec2(id, cycle + 9.))) * fade;
    vec3 position = centre + side * (VertexUV.x - .5) * 4.5 * scale + up * (VertexUV.y - .5) * 10. * scale;
    vec3 rest = mix(backdropLow, backdropHigh, smoothstep(.25, .6, v));
    vec3 tint = mix(backdropMid, backdropTreble, smoothstep(.25, .6, v));
    wispColor = mix(rest, tint, clamp(energy * 1.5, 0., 1.)) * fade * (.5 + energy);
    wispSeed = hash(vec2(id, cycle + 10.));
    return ClipFromLocal * vec4(position, 1.);
  }
]]
shader.wispFragment = [[
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;

  in vec3 wispColor;
  in float wispSeed;

  vec4 lovrmain() {
    vec2 p = UV - .5;
    // A soft, tall glow with a few faint streaks along its length. The Gaussian alone leaves a few percent of
    // its light at the quad's border, which shows as a straight edge against the dark sky, so a window that
    // reaches zero at every edge bounds it.
    vec2 edge = 1. - 4. * p * p;
    float shape = exp(-p.x * p.x * 14.) * exp(-p.y * p.y * 10.) * edge.x * edge.x * edge.y * edge.y;
    float streaks = .7 + .3 * sin(UV.x * 13. + wispSeed * 40.);
    vec3 light = wispColor * shape * streaks * backdropScene.x * backdropResponse.w * .6;
    float peak = max(max(light.r, light.g), light.b);
    light *= min(1., .6 / max(peak, .0001));
    return vec4(light, clamp(peak * .2, 0., .12));
  }
]]

return shader
