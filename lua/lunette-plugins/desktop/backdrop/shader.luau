-- Analytic, texture-free sky and three translucent curtain layers, with premultiplied output.
-- Each coarse band keeps its own colour and action. Bass heaves the curtains and flashes the horizon, mid sends
-- a travelling ripple, and treble scatters glints through the strands and stars. The curtain's height is a
-- spectrum: the lowest band lights its lower fringe and the highest band its crest.
local model = require './model'

local shader = {}

-- Waves arrive as (age, faded strength, longitude, band), with band 1 bass, 2 mid, and 3 treble.
local WAVES = [[
  const int WAVES = WAVE_COUNT;
  uniform vec4 backdropWaves[WAVES];

  float ringDistance(float u, float position) {
    return abs(fract(u - position + .5) - .5);
  }
]]

local function withWaves(source: string): string
  local waves = string.gsub(WAVES, 'WAVE_COUNT', tostring(model.MAX_WAVES))
  return (string.gsub(waves .. source, 'TREBLE_LIFETIME', string.format('%.4f', model.waveLifetimes.treble)))
end

shader.skyVertex = [[
  vec4 lovrmain() {
    return DefaultPosition;
  }
]]
shader.skyFragment = withWaves [[
  uniform vec4 backdropSky;
  uniform vec4 backdropResponse;
  uniform vec3 backdropZenith;
  uniform vec3 backdropHorizon;
  uniform vec3 backdropGlint;
  uniform vec3 backdropBass;
  uniform vec3 backdropTreble;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  vec4 lovrmain() {
    float height = sin((UV.y - .5) * 3.14159265);
    float up = smoothstep(0., .85, height);
    vec3 sky = mix(backdropHorizon, backdropZenith, up);
    sky *= mix(.18, 1., smoothstep(-.2, .12, height));
    // A thin band at the horizon; overlapping heaves from steady kicks must not become a sky-wide wash.
    float horizon = 1. - smoothstep(0., .06, abs(height - .02));
    float flash = 0.;
    float burst = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(UV.x, wave.z);
      if (wave.w < 1.5) {
        float front = distance - wave.x * .32;
        flash += wave.y * exp(-front * front * 120.);
      } else if (wave.w > 2.5) {
        burst += wave.y * exp(-distance * distance * 300.);
      }
    }
    vec2 cell = floor(UV * vec2(360., 180.));
    vec2 point = fract(UV * vec2(360., 180.)) - .5;
    float seed = hash(cell);
    float shape = 1. - smoothstep(.015, .08, length(point));
    float star = step(.998, seed) * shape;
    // A treble burst adds stars of its own and lights them only in the treble hue.
    float extra = step(.998 - .004 * min(burst, 1.), seed) * shape;
    float rate = .0092038847 * (1. + backdropResponse.z * 3.);
    float twinkle = .6 + .4 * sin(backdropSky.y * rate + seed * 6.2831853);
    float above = smoothstep(.05, .5, height);
    sky += backdropGlint * star * twinkle * above * .13;
    sky += backdropTreble * extra * twinkle * above * min(burst, 1.) * .5;
    sky = clamp(sky * backdropSky.z, 0., .12);
    sky += backdropBass * flash * horizon * .07 * backdropSky.z;
    float alpha = clamp(backdropSky.x, 0., 1.);
    return vec4(clamp(sky, 0., .2) * alpha, alpha);
  }
]]
shader.curtainVertex = withWaves [[
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
    vec3 band = backdropResponse.xyz * backdropFocus.xyz;
    float fold = sin(phase * 5. + time * 13.) + .45 * sin(phase * 11. - time * 9.);
    float heave = 0.;
    float ripple = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(u, wave.z);
      if (wave.w < 1.5) {
        float front = distance - wave.x * .32;
        heave += wave.y * exp(-front * front * 120.);
      } else if (wave.w < 2.5) {
        float front = distance - wave.x * .1;
        ripple += wave.y * exp(-front * front * 900.) * sin(front * 80.);
      }
    }
    heave = min(heave, 1.5);
    float fine = band.z * sin(phase * 29. + time * 23.) * pow(1. - v, 3.) * .012;
    float elevation = .12 + layer * .14 + sin(phase * 2. + time * 7.) * (.035 + band.x * .03);
    elevation += v * (.25 + band.x * .09 + heave * .05) + fold * (.025 + band.y * .04);
    elevation += ripple * .022 + fine;
    float radius = backdropScene.w * (1. - layer * .055);
    radius += fold * (.16 + band.y * .28) + heave * 1.1;
    vec3 position = vec3(sin(angle) * cos(elevation), sin(elevation), cos(angle) * cos(elevation)) * radius;
    return ClipFromLocal * vec4(position, 1.);
  }
]]
shader.curtainFragment = withWaves [[
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;
  uniform vec4 backdropFocus;
  uniform vec4 backdropSpectrum[2];
  uniform vec3 backdropLow;
  uniform vec3 backdropHigh;
  uniform vec3 backdropBass;
  uniform vec3 backdropMid;
  uniform vec3 backdropTreble;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  vec3 bandColour(float t) {
    return t < .5 ? mix(backdropBass, backdropMid, t * 2.) : mix(backdropMid, backdropTreble, t * 2. - 1.);
  }
  float spectrum(int index) {
    vec4 group = backdropSpectrum[index / 4];
    int lane = index - (index / 4) * 4;
    return lane == 0 ? group.x : lane == 1 ? group.y : lane == 2 ? group.z : group.w;
  }
  vec4 lovrmain() {
    float u = UV.x;
    float v = UV.y;
    float visibility = backdropScene.x;
    float time = backdropScene.y * (6.28318530718 / 4096.);
    float phase = u * 6.28318530718 + backdropScene.z * 1.8;
    vec3 band = backdropResponse.xyz * backdropFocus.xyz;
    float feather = smoothstep(0., .14, v) * (1. - smoothstep(.48, 1., v));
    float strands = .55 + .3 * sin(phase * 43. + sin(phase * 7. - time * 11.) * 2.);
    strands += (.15 + band.z * .2) * sin(phase * 89. + time * 17.);
    strands += band.z * .12 * sin(phase * 157. - time * 41.);
    float folds = .65 + .35 * sin(phase * 5. + time * 13.);
    float edge = 1. + band.z * .12 * sin(phase * 29. + time * 23.);
    float rays = max(strands, 0.) * folds;
    float coverage = feather * rays * edge;

    vec3 base = mix(backdropLow, backdropHigh, smoothstep(.12, .9, v));
    vec3 focus = backdropBass * backdropFocus.x + backdropMid * backdropFocus.y + backdropTreble * backdropFocus.z;
    focus /= max(dot(backdropFocus.xyz, vec3(1.)), .001);
    vec3 color = mix(base, focus, .25 + .35 * clamp(max(band.x, max(band.y, band.z)), 0., 1.));

    vec3 lit = vec3(0.);
    float glow = 0.;
    for (int i = 0; i < 8; i++) {
      float offset = (v - (.07 + float(i) * .08)) / .07;
      float energy = spectrum(i) * exp(-offset * offset);
      lit += bandColour(float(i) / 7.) * energy;
      glow += energy;
    }

    float flash = 0.;
    float swell = 0.;
    float crest = 0.;
    float sparkle = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(u, wave.z);
      if (wave.w < 1.5) {
        float front = distance - wave.x * .32;
        float reach = wave.y * exp(-front * front * 120.);
        swell += reach;
        flash += reach * (1. - smoothstep(0., .4, v));
      } else if (wave.w < 2.5) {
        float front = distance - wave.x * .1;
        crest += wave.y * exp(-front * front * 900.);
      } else {
        // Cells are roughly square on the curtain, about 0.4 m at the default distance. A lit cell holds one
        // soft point at a jittered centre, so glints read as stars rather than as blocks of the grid.
        vec2 grid = vec2(u * 420., v * 16.);
        vec2 cell = floor(grid);
        float seed = hash(cell + float(i) * 17.);
        vec2 centre = vec2(hash(cell + 3.1), hash(cell + 7.3)) * .4 + .3;
        float point = 1. - smoothstep(0., .3, length(fract(grid) - centre));
        // Each lit cell twinkles once, at its own moment within the wave's life, instead of holding steady.
        float moment = (wave.x / TREBLE_LIFETIME - .1 - hash(cell + 11.) * .6) / .08;
        float twinkle = exp(-moment * moment);
        float near = exp(-distance * distance * 500.);
        sparkle += wave.y * near * step(.88, seed) * point * twinkle * rays * smoothstep(.05, .2, v);
      }
    }
    flash = min(flash, 1.5);
    crest = min(crest, 1.5);
    sparkle = min(sparkle, 1.);

    // The whole swell takes the bass hue as it passes, with the brightest flash along the lower fringe.
    color = mix(color, backdropBass, clamp(swell, 0., 1.) * .55);
    color += lit * 1.4 + backdropBass * flash * 1.5 + backdropMid * crest * 1.2 + backdropTreble * sparkle * 2.;
    // Spectrum light follows the strands, so band slices cannot draw horizontal lines across the gaps.
    float alpha = coverage * .3 + (glow * .18 * rays + flash * .2 + crest * .12) * feather + sparkle * .25;
    alpha = clamp(alpha * visibility, 0., .42);
    color = clamp(color * backdropResponse.w, 0., .75);
    return vec4(color * alpha, alpha);
  }
]]

return shader
