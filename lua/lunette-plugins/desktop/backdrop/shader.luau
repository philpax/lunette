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
    float wander = sin(phase * 2. + layer * 2.1 + time * 52.) * .6 + sin(phase * 3. - layer * 1.3 - time * 38.) * .4;
    float open = clamp(level, 0., 1.);
    return smoothstep(-.6 - open * .8, .3 - open * .6, wander);
  }
]]

-- Autonomous terms take time in radians per 4096 units of model time, which advances at the motion strength
-- in units per second. Their multipliers are whole numbers so every term is continuous where the clock wraps;
-- a multiplier of 140 completes a cycle in about 29 seconds at full motion.

-- Wavefront speeds in turns of the ring per second.
local BASS_SPEED = 0.3
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
  out vec3 skyDirection;

  vec4 lovrmain() {
    skyDirection = VertexPosition.xyz;
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

  in vec3 skyDirection;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  // An integer hash of a lattice point. A sine hash is not exact: at the arguments this field reaches, a
  // rounding difference in the last bit changes its result entirely, and a GPU may compute the corner two cells
  // share differently from each side, which tears the noise along cell edges into angular shards.
  float lattice(ivec2 cell) {
    uvec2 q = uvec2(cell);
    uint h = q.x * 1597334677u ^ q.y * 3812015801u;
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h) * (1. / 4294967296.);
  }
  float noise(vec2 p) {
    vec2 floored = floor(p);
    ivec2 i = ivec2(floored);
    vec2 f = p - floored;
    // Quintic interpolation is smooth in its second derivative, so no creases show along the cell edges.
    f = f * f * f * (f * (f * 6. - 15.) + 10.);
    float a = lattice(i);
    float b = lattice(i + ivec2(1, 0));
    float c = lattice(i + ivec2(0, 1));
    float d = lattice(i + ivec2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
  }
  float fbm(vec2 p) {
    float value = 0.;
    float amplitude = .5;
    for (int i = 0; i < 4; i++) {
      value += amplitude * noise(p);
      // Each octave turns as well as scales, so the octaves' grids never line up into visible lines.
      p = mat2(.8, .6, -.6, .8) * p * 2.03 + vec2(1.7, 9.2);
      amplitude *= .5;
    }
    return value;
  }
  vec2 circle(float angle) {
    return vec2(cos(angle), sin(angle));
  }
  // Patchy aurora overhead: elongated patches drift, shear, and swirl through a fluctuating field, forming and
  // dissolving as it changes, and each breathes in and out on its own phase as pulsating aurora does. Every
  // time term moves around a circle with a whole-number multiplier, so the field is continuous where the clock
  // wraps.
  vec3 overhead(vec3 direction, float time, float energy, out vec2 projected, out vec2 field, out float density) {
    // Stereographic coordinates from the nadir have no seam at the zenith.
    vec2 q = direction.xz / (1. + direction.y) * 3.;
    projected = q;
    float twist = .5 * sin(time * 20.) + .7 * length(q) * sin(time * 31.);
    q = mat2(cos(twist), sin(twist), -sin(twist), cos(twist)) * q;
    vec2 warp = vec2(fbm(q * 1.1 + circle(time * 45.) * 1.5), fbm(q * 1.1 + vec2(5.2, 1.3) + circle(time * 37. + 1.) * 1.5));
    field = q + (warp - .5) * 1.4;
    density = fbm(field * vec2(1.6, 3.) + circle(time * 23.) * .8);
    float pulse = .5 + .5 * sin(time * 160. + fbm(q * .7) * 9.);
    float threshold = .6 - .12 * energy;
    // A wide edge keeps the patches diffuse, and fine streaks along the field give them the texture of rays.
    float cloud = smoothstep(threshold - .08, threshold + .3, density) * mix(.25, 1., pulse);
    // The streaks are a warped sine rather than stretched noise, whose stretched cells would show as straight lines.
    float streaks = .55 + .45 * sin(field.y * 26. + fbm(field * 2. + 7.7) * 7.);
    vec3 color = mix(backdropMid, backdropTreble, smoothstep(.35, .7, fbm(field * .8 + 3.1)));
    return color * cloud * streaks * (.08 + .22 * energy);
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
    // The direction comes from the interpolated position, not from UV. Near the zenith one triangle spans a wide
    // range of longitude, and UV interpolated across it bends the field into visible facets at every edge.
    vec3 direction = normalize(skyDirection);
    float energy = dot(backdropResponse.xyz, vec3(1. / 3.));
    float time = backdropSky.y * (TAU / 4096.);
    vec2 projected;
    vec2 warped;
    float density;
    vec3 patches = overhead(direction, time, energy, projected, warped, density);
    int view = int(backdropSky.w + .5);
    if (view == 1) {
      return vec4(direction * .5 + .5, 1.);
    } else if (view == 2) {
      return vec4(fract(projected), 0., 1.);
    } else if (view == 3) {
      ivec2 cell = ivec2(floor(warped * vec2(1.6, 3.)));
      return vec4(lattice(cell), lattice(cell + ivec2(7, 3)), lattice(cell + ivec2(2, 9)), 1.);
    } else if (view == 4) {
      return vec4(vec3(density), 1.);
    } else if (view == 5) {
      return vec4(patches * 6., 1.);
    }
    vec3 field = patches * smoothstep(.3, .65, height) * backdropSky.z;
    float alpha = clamp(backdropSky.x, 0., 1.);
    return vec4((clamp(sky * backdropSky.z, 0., .12) + min(field, vec3(.35))) * alpha, alpha);
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
    float fold = sin(phase * 5. + time * 140.) + .45 * sin(phase * 11. - time * 98.);
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
    float fine = band.z * sin(phase * 29. + time * 315.) * pow(1. - v, 3.) * .012;
    // Each curtain tilts on its own slow cycle, so the curtains cross and weave instead of stacking in parallel.
    float tilt = sin(angle + layer * 2.4 + time * 32.) * .06;
    float elevation = .15 + layer * .07 + tilt + sin(phase * 2. + time * 70.) * (.035 + band.x * .03);
    // Rays rise further as the music grows, toward the zenith at full energy, and a treble onset shoots them up.
    float height = (.38 + .32 * energy + band.z * .1 + heave * .06 + min(surge, 1.) * .08) * (.5 + .5 * reach);
    elevation += v * height + fold * (.025 + band.y * .04);
    elevation += ripple * .022 + fine + v * min(lift, 1.) * .06;
    // In plan view each curtain meanders toward and away from the viewer in broad folds, so the curtains overlap
    // in depth and perspective makes the nearer stretches tower over the farther ones.
    float meander = sin(angle * 2. + layer * 2.1 + time * 42.) * .2 + sin(angle * 5. - layer * 1.4 + time * 91.) * .07;
    float radius = backdropScene.w * (1. + meander - layer * .05);
    // Folds swing the curtain several metres toward and away from the viewer as they travel along it.
    radius += fold * (1.8 + band.y * 1.5) + heave * 1.1;
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

  // A travelling wavefront as a few concentric ripples under one envelope, centred on the leading ring.
  float ripple(float front) {
    return exp(-front * front * 180.) * (.55 + .45 * cos(front * 110.));
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

    // Rays lean and wander as they rise, so they read as light streaming along field lines rather than as
    // straight bars.
    float lean = v * (.08 * sin(phase * 3. + time * 70.) + .04 * sin(phase * 7. - time * 105.));
    float q = phase + lean;
    float r1 = .5 + .5 * sin(q * 43. + sin(q * 7. - time * 105.) * 2.);
    float r2 = .5 + .5 * sin(q * 89. + time * 175.);
    float r3 = .5 + .5 * sin(q * 157. - time * 245.);
    // Soft, uneven rays. Squares sharpen the sines a little without cutting dark gaps between them.
    float rays = r1 * r1 * .5 + r2 * r2 * .3 + (.1 + band.z * .25) * r3 * r3;
    // Brightness streams up each ray, so no ray is a uniform pillar and the curtain seems to flow upward.
    float streak = .75 + .25 * sin(v * 7. + r1 * 3. - time * 525.);
    float folds = .6 + .4 * sin(phase * 5. + time * 140.);
    // Ray tops reach different heights along the curtain.
    float tops = .7 + .2 * sin(phase * 9. + time * 88.) + .1 * sin(phase * 23. - time * 122.);

    float flash = 0.;
    float crest = 0.;
    float surge = 0.;
    for (int i = 0; i < WAVES; i++) {
      vec4 wave = backdropWaves[i];
      float distance = ringDistance(u, wave.z);
      if (wave.w < 1.5) {
        float front = distance - wave.x * BASS_SPEED;
        // A kick punches at its origin, then ripples outward both ways as narrow rings that fade over the
        // wave's life. The rings are narrow, so steady kicks never hold the whole curtain in the bass colour.
        flash += wave.y * exp(-distance * distance * 300.) * exp(-wave.x * 8.);
        flash += wave.y * ripple(front) * exp(-wave.x * 1.2);
      } else if (wave.w < 2.5) {
        float front = distance - wave.x * MID_SPEED;
        crest += wave.y * ripple(front) * exp(-wave.x * 1.5);
      } else {
        // A treble burst swells in over a few frames rather than popping, which would strobe.
        surge += wave.y * exp(-distance * distance * 160.) * exp(-wave.x * 3.) * smoothstep(0., .08, wave.x);
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
    light += (backdropHigh * .4 + backdropTreble * (1.6 * treble + surge * 2. * (.4 + r3 * r3))) * high;
    float extent = max(ribbon(phase, layer, time, own), clamp(flash + crest + surge, 0., 1.));
    light *= hem * fade * (.4 + .6 * rays) * streak * folds * extent * visibility * backdropResponse.w * .7;

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
