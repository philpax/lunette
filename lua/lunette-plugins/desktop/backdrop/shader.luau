-- Analytic, texture-free sky and three translucent curtain layers, with premultiplied output.
local shader = {}

shader.skyVertex = [[
  vec4 lovrmain() {
    return DefaultPosition;
  }
]]
shader.skyFragment = [[
  uniform vec4 backdropSky;
  uniform vec3 backdropZenith;
  uniform vec3 backdropHorizon;
  uniform vec3 backdropGlint;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
  }
  vec4 lovrmain() {
    float height = sin((UV.y - .5) * 3.14159265);
    float up = smoothstep(0., .85, height);
    vec3 sky = mix(backdropHorizon, backdropZenith, up);
    sky *= mix(.18, 1., smoothstep(-.2, .12, height));
    vec2 cell = floor(UV * vec2(360., 180.));
    vec2 point = fract(UV * vec2(360., 180.)) - .5;
    float star = step(.998, hash(cell)) * (1. - smoothstep(.015, .08, length(point)));
    float twinkle = .6 + .4 * sin(backdropSky.y * .0092038847 + hash(cell) * 6.2831853);
    sky += backdropGlint * star * twinkle * smoothstep(.05, .5, height) * .13;
    float alpha = clamp(backdropSky.x, 0., 1.);
    return vec4(clamp(sky * backdropSky.z, 0., .12) * alpha, alpha);
  }
]]
shader.curtainVertex = [[
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;
  uniform vec4 backdropWaves[8];

  vec4 lovrmain() {
    float u = VertexUV.x;
    float v = VertexUV.y;
    float layer = backdropScene.z;
    float time = backdropScene.y * (TAU / 4096.);
    float angle = TAU * u;
    float phase = angle + layer * 1.8;
    float bass = backdropResponse.x;
    float fold = sin(phase * 5. + time * 13.) + .45 * sin(phase * 11. - time * 9.);
    float wave = 0.;
    for (int i = 0; i < 8; i++) {
      float distance = abs(fract(u - backdropWaves[i].z + .5) - .5);
      float front = distance - backdropWaves[i].x * .1;
      wave += backdropWaves[i].y * exp(-front * front * 900.) * sin(front * 80.);
    }
    float ripple = backdropResponse.z * sin(phase * 29. + time * 23.) * pow(1. - v, 3.) * .012;
    float elevation = .12 + layer * .14 + sin(phase * 2. + time * 7.) * (.035 + bass * .025);
    elevation += v * (.25 + bass * .07) + fold * (.025 + backdropResponse.y * .035);
    elevation += wave * .022 + ripple;
    float radius = backdropScene.w * (1. - layer * .055);
    radius += fold * (.16 + backdropResponse.y * .24);
    vec3 position = vec3(sin(angle) * cos(elevation), sin(elevation), cos(angle) * cos(elevation)) * radius;
    return ClipFromLocal * vec4(position, 1.);
  }
]]
shader.curtainFragment = [[
  uniform vec4 backdropScene;
  uniform vec4 backdropResponse;
  uniform vec3 backdropLow;
  uniform vec3 backdropHigh;

  vec4 lovrmain() {
    float time = backdropScene.y * (6.28318530718 / 4096.);
    float phase = UV.x * 6.28318530718 + backdropScene.z * 1.8;
    float feather = smoothstep(0., .14, UV.y) * (1. - smoothstep(.48, 1., UV.y));
    float strands = .55 + .3 * sin(phase * 43. + sin(phase * 7. - time * 11.) * 2.);
    strands += .15 * sin(phase * 89. + time * 17.);
    float folds = .65 + .35 * sin(phase * 5. + time * 13.);
    float edge = 1. + backdropResponse.z * .12 * sin(phase * 29. + time * 23.);
    float alpha = clamp(feather * strands * folds * edge * .3 * backdropScene.x, 0., .32);
    vec3 color = mix(backdropLow, backdropHigh, smoothstep(.12, .9, UV.y));
    color = clamp(color * backdropResponse.w, 0., .65);
    return vec4(color * alpha, alpha);
  }
]]

return shader
