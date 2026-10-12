-- Analytic, texture-free sky and three emissive curtains, with premultiplied output.
-- Every curtain carries the spectrum by altitude: bass lights its lower hem, mid its body, and treble its ray
-- tops. Each band also has its own onset action: bass heaves the curtains and flashes the hem, mid sends a
-- whitened flare along the body, and treble shoots and flickers the rays and lights nearby stars.
local model = require './model'

local shader = {}

-- Waves arrive as (age, faded strength, longitude, band), with band 1 bass, 2 mid, and 3 treble.
local WAVES = [[
  const int WAVES = WAVE_COUNT;
  uniform vec4 backdropWaves[WAVES];

  float ringDistance(float u, float position) {
    return abs(fract(u - position + .5) - .5);
  }

  // A layer's extent around the ring. Quiet, it breaks into separate drifting arcs; as its band grows louder
  // the gaps close until the curtain encircles the sky.
  float ribbon(float phase, float layer, float time, float level) {
    float wander = sin(phase * 2. + layer * 2.1 + time * 1.7) * .6 + sin(phase * 3. - layer * 1.3 - time * 1.1) * .4;
    float open = clamp(level, 0., 1.);
    return smoothstep(-.6 - open * .8, .3 - open * .6, wander);
  }
]]

-- Wavefront speeds in turns of the ring per second.
local BASS_SPEED = 0.22
local MID_SPEED = 0.16

local function withWaves(source: string): string
  local waves = string.gsub(WAVES, 'WAVE_COUNT', tostring(model.MAX_WAVES))
  local constants: { [string]: string } = {
    BASS_SPEED = string.format('%.4f', BASS_SPEED),
    MID_SPEED = string.format('%.4f', MID_SPEED),
  }
  -- Only the named constants are replaced; other upper-case words such as WAVES and UV are left alone.
  return (
    string.gsub(waves .. source, '[%u_]+', function(name: string): string
      return constants[name] or name
    end)
  )
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
  uniform vec3 backdropTreble;
  uniform vec3 backdropMid;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  vec4 lovrmain() {
    float height = sin((UV.y - .5) * 3.14159265);
    float up = smoothstep(0., .85, height);
    vec3 sky = mix(backdropHorizon, backdropZenith, up);
    sky *= mix(.18, 1., smoothstep(-.2, .12, height));
    float burst = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      if (wave.w > 2.5) {
        float distance = ringDistance(UV.x, wave.z);
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
    sky += backdropTreble * extra * twinkle * above * min(burst, 1.) * .6;
    // The curtains' light spills into the low sky as a faint airglow that swells with the mid band.
    float airglow = exp(-abs(height - .3) * 6.) * smoothstep(.08, .2, height);
    sky += backdropMid * airglow * (.005 + .015 * backdropResponse.y);
    float alpha = clamp(backdropSky.x, 0., 1.);
    return vec4(clamp(sky * backdropSky.z, 0., .12) * alpha, alpha);
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
    float energy = dot(backdropResponse.xyz, vec3(1. / 3.));
    float fold = sin(phase * 5. + time * 13.) + .45 * sin(phase * 11. - time * 9.);
    float heave = 0.;
    float ripple = 0.;
    float lift = 0.;
    float surge = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(u, wave.z);
      if (wave.w < 1.5) {
        float front = distance - wave.x * BASS_SPEED;
        heave += wave.y * exp(-front * front * 120.);
      } else if (wave.w < 2.5) {
        float front = distance - wave.x * MID_SPEED;
        ripple += wave.y * exp(-front * front * 900.) * sin(front * 80.);
        lift += wave.y * exp(-front * front * 250.);
      } else {
        surge += wave.y * exp(-distance * distance * 160.);
      }
    }
    heave = min(heave, 1.5);
    float own = layer < .5 ? backdropResponse.x : layer < 1.5 ? backdropResponse.y : backdropResponse.z;
    // A passing onset restores full height, so an onset in a gap raises a curtain rather than a thread.
    float reach = max(ribbon(phase, layer, time, own), min(heave + lift + surge, 1.));
    float fine = band.z * sin(phase * 29. + time * 23.) * pow(1. - v, 3.) * .012;
    // Each curtain tilts on its own slow cycle, so the curtains cross and weave instead of stacking in parallel.
    float tilt = sin(angle + layer * 2.4 + time * 1.5) * .06;
    float elevation = .15 + layer * .07 + tilt + sin(phase * 2. + time * 7.) * (.035 + band.x * .03);
    // Rays rise further as the music grows, toward the zenith at full energy, and a treble onset shoots them up.
    float height = (.38 + .32 * energy + band.z * .1 + heave * .06 + min(surge, 1.) * .08) * (.5 + .5 * reach);
    elevation += v * height + fold * (.025 + band.y * .04);
    elevation += ripple * .022 + fine + v * min(lift, 1.) * .06;
    // In plan view each curtain meanders toward and away from the viewer in broad folds, so the curtains overlap
    // in depth and perspective makes the nearer stretches tower over the farther ones.
    float meander = sin(angle * 2. + layer * 2.1 + time * 1.3) * .2 + sin(angle * 5. - layer * 1.4 + time * 2.9) * .07;
    float radius = backdropScene.w * (1. + meander - layer * .05);
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
    float layer = backdropScene.z;
    float phase = u * 6.28318530718 + layer * 1.8;
    vec3 band = backdropResponse.xyz * backdropFocus.xyz;
    float own = layer < .5 ? backdropResponse.x : layer < 1.5 ? backdropResponse.y : backdropResponse.z;

    // Every curtain carries the whole spectrum by altitude, as a real one does: bass lights the lower hem, mid
    // the body, and treble the ray tops. Each coarse band averages its own sub-bands, and the level is squared
    // so a quiet band leaves its zone near rest and a loud one takes it over.
    float bass = (spectrum(0) + spectrum(1) + spectrum(2)) / 3.;
    float mid = (spectrum(3) + spectrum(4) + spectrum(5)) / 3.;
    float treble = (spectrum(6) + spectrum(7)) / 2.;
    bass *= bass;
    mid *= mid;
    treble *= treble;

    float r1 = .5 + .5 * sin(phase * 43. + sin(phase * 7. - time * 11.) * 2.);
    float r2 = .5 + .5 * sin(phase * 89. + time * 17.);
    float r3 = .5 + .5 * sin(phase * 157. - time * 41.);
    // Thin, uneven rays: powers sharpen the sines into bright lines with darker gaps between them.
    float rays = r1 * r1 * .55 + r2 * r2 * r2 * .3 + (.15 + band.z * .35) * pow(r3, 4.);
    float folds = .6 + .4 * sin(phase * 5. + time * 13.);
    // Ray tops reach different heights along the curtain.
    float tops = .7 + .2 * sin(phase * 9. + time * 5.) + .1 * sin(phase * 23. - time * 8.);

    float flash = 0.;
    float crest = 0.;
    float surge = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(u, wave.z);
      if (wave.w < 1.5) {
        float front = distance - wave.x * BASS_SPEED;
        // The heave lingers, but the colour punches and decays within a beat so steady kicks still pulse.
        flash += wave.y * exp(-front * front * 120.) * exp(-wave.x * 6.5);
      } else if (wave.w < 2.5) {
        float front = distance - wave.x * MID_SPEED;
        crest += wave.y * exp(-front * front * 300.) * exp(-wave.x * 3.);
      } else {
        surge += wave.y * exp(-distance * distance * 160.) * exp(-wave.x * 4.);
      }
    }
    flash = min(flash, 1.5);
    crest = min(crest, 1.5);
    surge = min(surge, 1.5);

    float hem = smoothstep(0., .03, v);
    float reachTop = tops + surge * .3;
    float fade = 1. - smoothstep(reachTop * .25, reachTop, v);
    // A kick's flash climbs from the hem into the body before it decays.
    float low = exp(-v * 14. / (1. + flash * 2.5));
    float body = smoothstep(0., .06, v) * exp(-v * 2.2);
    float high = smoothstep(.25, .6, v) * (1. - smoothstep(.7, 1., v));
    vec3 light = backdropBass * low * (.35 + 2.4 * bass + 3. * flash);
    vec3 flare = mix(backdropMid, vec3(1.), .25);
    // At rest the body and tops keep the natural aurora's low and high colours; each band's own colour takes over
    // its zone as the band grows loud.
    light += (backdropLow * .75 + backdropMid * 1.8 * mid) * body + flare * body * crest * 2.2;
    // A treble onset flickers individual rays up the curtain rather than lighting it evenly.
    light += (backdropHigh * .4 + backdropTreble * (1.6 * treble + surge * 3. * (.3 + r3 * r3 * 1.4))) * high;
    float extent = max(ribbon(phase, layer, time, own), clamp(flash + crest + surge, 0., 1.));
    light *= hem * fade * (.25 + .75 * rays) * folds * extent * visibility * backdropResponse.w * .55;

    // The light is emitted rather than painted: alpha stays below the colour so overlapping curtains add up and
    // glow, while still dimming the stars behind them a little.
    float peak = max(max(light.r, light.g), light.b);
    // Scaling by the brightest channel limits the colour without bleaching it; what exceeds the bound turns a
    // little toward white, so the hottest cores glow instead of clipping into flat colour.
    float over = max(peak - .9, 0.);
    light *= min(1., .9 / max(peak, .0001));
    light += vec3(min(over, 1.) * .18);
    float alpha = clamp(peak * .2, 0., .2);
    return vec4(light, alpha);
  }
]]

return shader
