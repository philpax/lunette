-- Shared GLSL for the unmasked overhead light in the analytic sky and compute texture.
return [[
  // An integer hash keeps shared noise corners exact across adjacent cells.
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
  // Whole-number time multipliers keep the field continuous where the model clock wraps.
  vec3 overheadAt(vec2 q, float time, float energy, out vec2 field, out float density) {
    float twist = .5 * sin(time * 20.) + .7 * length(q) * sin(time * 31.);
    q = mat2(cos(twist), sin(twist), -sin(twist), cos(twist)) * q;
    vec2 warp = vec2(fbm(q * 1.1 + circle(time * 45.) * 1.5), fbm(q * 1.1 + vec2(5.2, 1.3) + circle(time * 37. + 1.) * 1.5));
    field = q + (warp - .5) * 1.4;
    density = fbm(field * vec2(1.6, 3.) + circle(time * 23.) * .8);
    float threshold = .6 - .12 * energy;
    // A zero-density patch emits no light, so its pulse, rays, and colour need no further noise samples.
    float cloud = smoothstep(threshold - .08, threshold + .3, density);
    if (cloud == 0.) return vec3(0.);
    float pulse = .5 + .5 * sin(time * 160. + fbm(q * .7) * 9.);
    // A wide edge keeps the patches diffuse, and fine streaks along the field give them the texture of rays.
    cloud *= mix(.25, 1., pulse);
    // The streaks are a warped sine rather than stretched noise, whose stretched cells would show as straight lines.
    float streaks = .55 + .45 * sin(field.y * 26. + fbm(field * 2. + 7.7) * 7.);
    vec3 color = mix(backdropMid, backdropTreble, smoothstep(.35, .7, fbm(field * .8 + 3.1)));
    return color * cloud * streaks * (.08 + .22 * energy);
  }
]]
