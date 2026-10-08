/**
 * The card shader: one full-screen pass draws the card as a still picture, with the studio behind it,
 * the card's edge, the face with its metal parts, foil and Regents crown, and the key resting in its
 * slot. The card faces the camera squarely and one fixed light falls on it from the upper right.
 */

export const CARD_WGSL = /* wgsl */ `
struct Params {
  res: vec2f,
  zoom: f32,
  light: vec2f,
  keyOrigin: vec2f,
  keyAxis: vec2f,
  metal: vec3f,
  metalRough: f32,
  metalKind: u32,
  crown: vec3f,
  crownRough: f32,
  crownKind: u32,
  patina: u32,
  shellGloss: f32,
  shellMetal: f32,
  shellClear: f32,
  shellPearl: f32,
  foilKind: u32,
}
@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var extAlb: texture_2d<f32>;
@group(0) @binding(2) var extAux: texture_2d<f32>;
@group(0) @binding(3) var extMat: texture_2d<f32>;
@group(0) @binding(4) var keyAlb: texture_2d<f32>;
@group(0) @binding(5) var keyAux: texture_2d<f32>;
@group(0) @binding(6) var samp: sampler;

const HALF = vec2f(0.625, 0.875);
const CARD = vec2f(1.25, 1.75);
const KEY_WID = 0.38235;
const EYE = vec3f(0.0, 0.0, 4.5);
const TAU = 6.2831853;
const CARD_TEXEL = vec2f(1.0 / 640.0, 1.0 / 896.0);
// The card faces the camera squarely: x runs right, y runs down the card, z comes out of the face.
const R3 = vec3f(1.0, 0.0, 0.0);
const D3 = vec3f(0.0, 1.0, 0.0);
const N3 = vec3f(0.0, 0.0, 1.0);
// The foil's strength and the moment the starlight sparkle is caught at.
const FOIL = 0.72;
const SPARKLE_T = 2.0;

struct Mat { tint: vec3f, rough: f32, kind: u32 }

fn cardUv(p: vec2f) -> vec2f { return p / CARD + 0.5; }
fn inside01(q: vec2f) -> bool { return all(q >= vec2f(0.0)) && all(q <= vec2f(1.0)); }
fn sdBox(p: vec2f, b: vec2f, r: f32) -> f32 { let q = abs(p) - b + r; return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r; }
fn lin(c: vec3f) -> vec3f { return pow(max(c, vec3f(0.0)), vec3f(2.2)); }
fn toWorld(n: vec3f) -> vec3f { return normalize(R3 * n.x + D3 * n.y + N3 * n.z); }
fn rot2(p: vec2f, a: f32) -> vec2f { let c = cos(a); let s = sin(a); return vec2f(c * p.x + s * p.y, -s * p.x + c * p.y); }

fn pcg2d(value: vec2u) -> vec2u {
  var h = value * 1664525u + 1013904223u;
  h.x = h.x + h.y * 1664525u;
  h.y = h.y + h.x * 1664525u;
  h = h ^ (h >> vec2u(16u));
  h.x = h.x + h.y * 1664525u;
  h.y = h.y + h.x * 1664525u;
  h = h ^ (h >> vec2u(16u));
  return h;
}
fn unitFloat(h: u32) -> f32 { return f32(h >> 8u) * (1.0 / 16777216.0); }
fn hash22(c: vec2f) -> vec2f { let h = pcg2d(bitcast<vec2u>(vec2i(floor(c)))); return vec2f(unitFloat(h.x), unitFloat(h.y)); }
fn vnoise(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let w = f * f * (3.0 - 2.0 * f);
  let a = hash22(i).x;
  let b = hash22(i + vec2f(1.0, 0.0)).x;
  let c = hash22(i + vec2f(0.0, 1.0)).x;
  let d = hash22(i + vec2f(1.0, 1.0)).x;
  return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}
fn fbm(p: vec2f) -> f32 {
  var s = 0.0;
  var a = 0.5;
  var q = p;
  for (var i = 0; i < 4; i++) { s += a * vnoise(q); q = q * 2.03 + vec2f(1.7, 9.2); a *= 0.5; }
  return s / 0.9375;
}

// Visible wavelengths in micrometres to display RGB, and a reflection grating: m * wavelength = d * dot(L + V, across).
fn wavelengthColor(w: f32) -> vec3f {
  let r = (vec3f(w) - vec3f(0.610, 0.545, 0.460)) / vec3f(0.045, 0.038, 0.032);
  let visible = smoothstep(0.380, 0.410, w) * (1.0 - smoothstep(0.700, 0.780, w));
  return exp(-0.5 * r * r) * visible;
}
fn diffraction(across: vec2f, lav: vec2f, spacing: f32) -> vec3f {
  let path = spacing * abs(dot(lav, across));
  let along = dot(lav, vec2f(-across.y, across.x));
  let envelope = exp(-along * along / 0.36);
  var c = vec3f(0.0);
  for (var order = 1; order <= 3; order++) { let m = f32(order); c += wavelengthColor(path / m) / (m * m); }
  return c * envelope;
}
fn pearlColor(phase: f32) -> vec3f { return vec3f(0.55, 0.52, 0.64) + vec3f(0.43, 0.40, 0.34) * cos(TAU * (phase + vec3f(0.05, 0.38, 0.63))); }
fn grain(point: vec2f) -> f32 {
  let p = vec2u(abs(point) * 2400.0);
  var n = (p.x * 1597334677u) ^ (p.y * 3812015801u);
  n = (n ^ (n >> 16u)) * 2246822519u;
  return f32(n & 1023u) / 1023.0 - 0.5;
}
fn aces(x: vec3f) -> vec3f { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), vec3f(0.0), vec3f(1.0)); }

// The studio: dark floor, warm bounce, cool rims, a soft box where the light is, and a strip light overhead.
fn studio(r: vec3f, rough: f32) -> vec3f {
  let up = -r.y;
  var c = mix(vec3f(0.03, 0.028, 0.026), vec3f(0.19, 0.2, 0.22), smoothstep(-0.7, 0.9, up));
  c += vec3f(0.22, 0.15, 0.09) * smoothstep(0.1, -0.8, up);
  c += vec3f(0.16, 0.24, 0.36) * pow(abs(r.x), 5.0);
  let box = normalize(vec3f(u.light.x * 0.7, u.light.y * 0.7 - 0.5, 1.2));
  let d = dot(r, box);
  let w = 0.04 + rough * 0.4;
  c += vec3f(3.2, 3.05, 2.9) * smoothstep(1.0 - w * 1.6, 1.0 - w * 0.3, d) / (1.0 + rough * 5.0);
  c += vec3f(0.45) * pow(max(d, 0.0), 12.0);
  c += vec3f(0.8) * smoothstep(0.72, 0.96, up) * (1.0 - rough * 0.6);
  return c;
}
fn hNormal(t: texture_2d<f32>, q: vec2f, texel: vec2f, k: f32) -> vec3f {
  let l = textureSampleLevel(t, samp, q - vec2f(texel.x, 0.0), 0.0).r;
  let r = textureSampleLevel(t, samp, q + vec2f(texel.x, 0.0), 0.0).r;
  let a = textureSampleLevel(t, samp, q - vec2f(0.0, texel.y), 0.0).r;
  let b = textureSampleLevel(t, samp, q + vec2f(0.0, texel.y), 0.0).r;
  return normalize(vec3f((l - r) * k, (a - b) * k, 1.0));
}

// Fingerprints: a few whorled smudges, each in its own cell of the card.
fn prints(p: vec2f) -> f32 {
  let cell = floor(p / 0.2);
  var amt = 0.0;
  for (var y = -1; y <= 1; y++) {
    for (var x = -1; x <= 1; x++) {
      let id = cell + vec2f(f32(x), f32(y));
      let h = hash22(id + vec2f(41.0, 7.0));
      if (h.x < 0.2) { continue; }
      let c = (id + 0.2 + 0.6 * hash22(id)) * 0.2;
      let d = rot2(p - c, h.y * TAU) * vec2f(1.0, 1.35);
      let r = length(d);
      amt = max(amt, smoothstep(0.09, 0.065, r) * (0.45 + 0.45 * sin(r * 260.0 + atan2(d.y, d.x) * 0.5)));
    }
  }
  return amt;
}
// Scratches: fine straight lines in three directions, each a short run along its own row.
fn scratches(p: vec2f) -> f32 {
  var s = 0.0;
  for (var k = 0; k < 3; k++) {
    let q = rot2(p, 0.4 + f32(k) * 1.1) * 150.0;
    let row = floor(q.y);
    let h = hash22(vec2f(row, f32(k) * 13.0 + 3.0));
    let h2 = hash22(vec2f(row * 0.37, f32(k) * 7.0 + 11.0));
    let run = step(0.78, h.x) * step(abs(fract(q.x / 160.0 + h.y) - 0.5), 0.12 + 0.25 * h2.x);
    s = max(s, run * (1.0 - smoothstep(0.05, 0.22, abs(fract(q.y) - 0.5))));
  }
  return s;
}

// A material lit by the studio, worn by the key's Patina. slope is how steeply the surface leans away from
// the face: 0 on flat tops, larger on bevels and edges.
fn metalColor(m: Mat, base: vec3f, n: vec3f, v: vec3f, l: vec3f, p: vec2f, lav: vec2f, slope: f32) -> vec3f {
  var tint = lin(m.tint) * base;
  var rough = m.rough;
  var specK = 1.0;
  var crust = vec4f(0.0);
  var glint = 0.0;
  var sheen = 0.0;
  let nz = fbm(p * 7.0);
  let rv = reflect(-v, n);
  // Each wear is laid over the lit metal as a surface layer (crust), because flat metal reflects the bright
  // studio light and plain darkening of its colour would not show.
  switch u.patina {
    case 0u: { rough *= 0.8; tint *= 1.05; }
    case 1u: {
      // polished: glossy, with soft broad reflections drifting across it
      rough *= 0.4; specK = 1.3;
      crust = vec4f(tint * 0.25, 0.7 * smoothstep(-0.2, 1.0, sin(rv.x * 4.0 + rv.y * 2.5 + p.x * 4.0 - p.y * 3.0)));
    }
    case 2u: {
      // satin: a soft brush running one way, made of fine streaks of differing length
      let across = dot(p, vec2f(-0.8, 0.6)) * 420.0;
      let streak = hash22(vec2f(floor(across), floor(dot(p, vec2f(0.6, 0.8)) * 6.0 + hash22(vec2f(floor(across), 9.0)).x * 3.0))).x;
      rough = max(rough + 0.35, 0.55); specK = 0.5;
      crust = vec4f(tint * 0.55, 0.3 + 0.4 * streak);
    }
    case 3u: { let hi = smoothstep(0.02, 0.2, slope); crust = vec4f(tint * 0.45, (1.0 - hi) * 0.85); rough = mix(rough + 0.25, rough * 0.5, hi); }
    case 4u: {
      // light tarnish: a warm brown dulling where the metal turns down into its recesses, a little on the flats
      let t = max(smoothstep(0.01, 0.09, slope), 0.4 * smoothstep(0.45, 0.75, nz));
      crust = vec4f(tint * vec3f(0.42, 0.26, 0.12) + lin(vec3f(0.12, 0.06, 0.02)), t); rough += 0.25 * t;
    }
    case 5u: { let f = prints(p); rough += f * 0.8; crust = vec4f(tint * 0.12 + vec3f(0.03, 0.028, 0.026), f); specK = 1.0 - 0.7 * f; }
    case 6u: { glint = scratches(p); rough += 0.06; }
    case 7u: { let a = smoothstep(0.42, 0.7, fbm(p * 11.0 + vec2f(4.0))) * (1.0 - 0.5 * smoothstep(0.05, 0.3, slope)); crust = vec4f(lin(vec3f(0.36, 0.7, 0.6)), a * 0.9); tint *= 0.85; }
    case 8u: { let s = smoothstep(0.3, 0.7, nz + p.y * 0.2); crust = vec4f(vec3f(0.035, 0.032, 0.03), s * 0.95); rough += 0.3 * s; }
    case 9u: {
      let ph = nz * 1.2 + p.x * 0.5 + p.y * 0.8;
      let film = vec3f(0.5) + vec3f(0.5) * cos(TAU * (vec3f(0.0, 0.33, 0.67) + ph));
      tint = mix(tint, lin(mix(vec3f(0.85, 0.6, 0.3), film, 0.75)) * 0.9, 0.7);
    }
    case 10u: {
      // gilded edges: a bright line of gold along every edge, rose gold on keys that are already gold-coloured
      let golden = tint.r > tint.b * 2.2 && tint.g > tint.b * 1.4;
      let edge = select(lin(vec3f(1.0, 0.76, 0.26)), lin(vec3f(0.98, 0.56, 0.54)), golden);
      crust = vec4f(edge * 1.9, smoothstep(0.03, 0.12, slope));
    }
    case 11u: {
      let e = max(step(0.72, fract((p.x + p.y) * 48.0)), step(0.72, fract((p.x - p.y) * 48.0))) * smoothstep(0.3, 0.5, fbm(p * 4.0));
      rough = mix(rough, 0.85, e); crust = vec4f(tint * 0.3, e * 0.95);
    }
    case 12u: { rough = 0.75; tint = mix(tint, vec3f(0.85), 0.3); glint = step(0.47, grain(p * 0.5)) * 0.6; }
    case 13u: {
      // mirror: crisp, hard-edged reflections of the room, bright and dark
      rough = 0.01; specK = 2.0; tint *= 1.1;
      let bars = step(0.0, sin(rv.x * 16.0 + rv.y * 7.0 + p.x * 6.0 - p.y * 4.0));
      crust = vec4f(tint * 0.05, 0.85 * (1.0 - bars));
    }
    case 14u: {
      let a = smoothstep(0.4, 0.62, fbm(p * 9.0 + vec2f(9.0))) * (1.0 - 0.5 * smoothstep(0.05, 0.3, slope));
      let green = vec4f(lin(vec3f(0.3, 0.55, 0.45)), a);
      let dull = vec4f(tint * vec3f(0.3, 0.24, 0.17), 0.82 + 0.16 * smoothstep(0.3, 0.65, nz));
      crust = select(dull, green, a > dull.a);
      rough = clamp(rough + 0.35, 0.0, 0.9);
    }
    case 15u: { rough *= 0.3; specK = 1.4; sheen = 1.0; }
    default: {}
  }
  rough = clamp(rough, 0.02, 0.95);
  let env = studio(reflect(-v, n), rough);
  let nl = max(dot(n, l), 0.0);
  let spec = pow(max(dot(n, normalize(l + v)), 0.0), mix(220.0, 24.0, rough)) * (1.2 - rough) * specK;
  let fres = pow(1.0 - max(dot(n, v), 0.0), 5.0);
  var c = env * tint + vec3f(spec) * mix(tint, vec3f(1.0), 0.3);
  switch m.kind {
    case 1u: { c = tint * (0.1 + 0.8 * nl) + env * (0.04 + 0.3 * fres) + vec3f(spec * 0.6); }
    case 2u: {
      let ph = dot(lav, vec2f(0.5, -0.3)) + p.y * 0.8 + fbm(p * 6.0) * 0.6;
      c = tint * (0.2 + 0.55 * nl) + lin(pearlColor(ph)) * 0.4 * (0.4 + nl) + env * 0.12 + vec3f(spec);
    }
    case 3u: { c = tint * 0.22 + env * (0.18 + 0.8 * fres) * mix(vec3f(1.0), tint, 0.4) + vec3f(spec * 1.4); }
    case 4u: {
      let sp = pow(max(grain(p * 0.7) + 0.5, 0.0), 30.0) * (0.5 + 0.5 * sin(SPARKLE_T * 3.0 + p.x * 40.0));
      c = tint * (0.35 + 0.5 * nl) + env * tint * 0.6 + vec3f(spec) + vec3f(1.0, 0.9, 0.7) * sp * 2.0;
    }
    case 5u: {
      let film = 0.5 + 0.5 * cos(TAU * (vec3f(0.0, 0.33, 0.67) + dot(n, v) * 1.3 + fbm(p * 3.0) * 0.4));
      c = env * mix(tint, film * vec3f(0.45, 0.5, 0.95), 0.55) + vec3f(spec);
    }
    default: {}
  }
  c += env * glint * 0.9 + vec3f(glint * spec * 2.0);
  c += lin(pearlColor(dot(lav, vec2f(0.5, -0.3)) + p.x * 1.5 + p.y)) * sheen * (0.12 + 0.5 * fres) * (0.4 + nl);
  c = mix(c, crust.rgb * (0.12 + 0.75 * nl) + env * 0.03, crust.a);
  return c;
}
fn keyMat() -> Mat { return Mat(u.metal, u.metalRough, u.metalKind); }
fn crownMat() -> Mat { return Mat(u.crown, u.crownRough, u.crownKind); }
// A Regents Club card's lettering: the Gold crown's metal.
fn clubGoldMat() -> Mat { return Mat(vec3f(1.0, 0.812, 0.345), 0.14, 0u); }

fn glitter(p: vec2f, lav: vec2f) -> f32 {
  let g = p * 90.0;
  let h = hash22(g);
  let h2 = hash22(g + vec2f(17.0, 5.0));
  let a = h.x * TAU;
  let f = vec2f(cos(a), sin(a)) * (0.3 + 0.7 * h.y);
  let align = pow(max(1.0 - length(lav * 0.5 - f * 0.6), 0.0), 18.0);
  let d = length(fract(g) - 0.5 - (h2 - 0.5) * 0.5);
  return align * exp(-d * d * 30.0) * step(0.45, h2.x) * 6.0;
}
fn foilColor(p: vec2f, lav: vec2f, illum: f32) -> vec3f {
  var across = vec2f(1.0, 0.0);
  var spacing = 1.5;
  var amt = 0.0;
  var pearl = 0.0;
  var fleck = 0.0;
  var sheen = 0.0;
  var tint = vec3f(1.0);
  let tang = normalize(vec2f(-p.y, p.x) + vec2f(1e-4));
  switch u.foilKind {
    case 0u: { sheen = 0.07; }
    case 1u: { pearl = 0.4; }
    case 2u: { across = normalize(vec2f(1.0, 0.35)); amt = 0.9; }
    case 3u: { across = normalize(vec2f(0.4, 1.0)); amt = 0.45; pearl = 0.2; spacing = 1.2; }
    case 4u: { fleck = 1.0; pearl = 0.08; }
    case 5u: { fleck = 1.0; tint = vec3f(1.0, 0.78, 0.4); pearl = 0.08; }
    case 6u: { fleck = 0.6; pearl = 0.18; tint = vec3f(0.8, 0.95, 1.0); }
    case 7u: { let a = hash22(p * 7.0 + vec2f(fbm(p * 5.0) * 1.2)).x * TAU; across = vec2f(cos(a), sin(a)); amt = 0.9; }
    case 8u: { across = tang; amt = 0.95; }
    case 9u: { fleck = 1.2; pearl = 0.35; tint = vec3f(0.8, 0.85, 1.0); across = tang; amt = 0.3; }
    case 10u: { across = tang; amt = 0.9 * step(0.5, fract(atan2(p.y, p.x) * 24.0 / TAU)) + 0.12; }
    case 11u: { let ch = (i32(floor(p.x * 8.0)) + i32(floor(p.y * 8.0))) & 1; across = select(vec2f(1.0, 0.0), vec2f(0.0, 1.0), ch == 1); amt = 0.85; }
    case 12u: { across = normalize(p + vec2f(1e-4)); spacing = 1.4 + 0.3 * sin(length(p) * 40.0); amt = 0.9; }
    case 13u: { let a = (fbm(p * 2.5 + vec2f(3.0)) + fbm(p * 2.5 - vec2f(5.0)) - 1.0) * 6.0; across = vec2f(cos(a), sin(a)); amt = 0.8; pearl = 0.2; }
    case 14u: { across = normalize(vec2f(1.0, -0.6)); amt = 1.4; }
    default: { across = normalize(p + vec2f(1e-4)); amt = 0.9; fleck = 0.8; pearl = 0.3; }
  }
  var c = diffraction(across, lav, spacing) * illum * amt;
  c += lin(pearlColor(dot(lav, vec2f(0.48, -0.32)) + p.y * 0.4)) * pearl * (0.3 + illum);
  c += tint * glitter(p, lav) * fleck;
  c += vec3f(sheen * illum);
  return c;
}

// ---------------- the card's face ----------------
fn exterior(q: vec2f, v: vec3f, l: vec3f, lav: vec2f, illum: f32) -> vec4f {
  let uv = cardUv(q);
  if (!inside01(uv)) { return vec4f(0.0); }
  let alb = textureSampleLevel(extAlb, samp, uv, 0.0);
  let aux = textureSampleLevel(extAux, samp, uv, 0.0);
  let mat = textureSampleLevel(extMat, samp, uv, 0.0);
  let nLocal = hNormal(extAux, uv, CARD_TEXEL, 7.0);
  let n = toWorld(nLocal);
  let slope = 1.0 - nLocal.z;
  let base = lin(alb.rgb);
  let nl = max(dot(n, l), 0.0);
  let nh = max(dot(n, normalize(l + v)), 0.0);
  let fres = pow(1.0 - max(dot(n, v), 0.0), 5.0);
  let g = u.shellGloss;
  let env = studio(reflect(-v, n), 1.0 - g);
  var shell = base * (0.1 + 0.9 * nl) + env * (0.03 + 0.3 * fres) * g + vec3f(pow(nh, mix(16.0, 260.0, g)) * g * 1.2);
  shell = mix(shell, env * base * 1.4 + vec3f(pow(nh, 120.0)), u.shellMetal);
  shell += lin(pearlColor(dot(lav, vec2f(0.48, -0.32)) + q.y * 0.5)) * u.shellPearl * 0.2 * (0.3 + nl);
  // a see-through shell shows the dark depth of the card behind its face
  shell = mix(shell, base * 0.1 + env * 0.06, u.shellClear * aux.b * 0.6);
  var c = shell;
  if (aux.g > 0.001) { c = mix(c, metalColor(keyMat(), base, n, v, l, q, lav, slope), aux.g); }
  if (mat.r > 0.001) { c = mix(c, metalColor(crownMat(), vec3f(0.85), n, v, l, q, lav, slope), mat.r); }
  if (mat.a > 0.001) { c = mix(c, metalColor(clubGoldMat(), vec3f(0.85), n, v, l, q, lav, slope), mat.a); }
  if (mat.g > 0.001) {
    let gem = base * (0.08 + 0.35 * nl) + base * studio(reflect(-v, n), 0.05) * 0.5 + vec3f(pow(nh, 300.0) * 3.0) + env * fres * 0.4;
    c = mix(c, gem, mat.g);
  }
  c += foilColor(q, lav, illum) * aux.b * (1.0 - aux.a * 0.7) * FOIL;
  // the light seam glows a saturated cool blue that holds its colour on pale cards
  c = mix(c, vec3f(0.12, 0.95, 2.6), clamp(mat.b * 1.3, 0.0, 1.0));
  return vec4f(c, alb.a);
}

// ---------------- the key ----------------
fn keyUv(pk: vec2f) -> vec3f {
  let perp = vec2f(-u.keyAxis.y, u.keyAxis.x);
  let d = pk - u.keyOrigin;
  let kuv = vec2f(dot(d, u.keyAxis), dot(d, perp) / KEY_WID + 0.5);
  return vec3f(kuv, select(0.0, 1.0, inside01(kuv)));
}
fn keyColor(pk: vec2f, v: vec3f, l: vec3f, lav: vec2f) -> vec4f {
  let kuv = keyUv(pk).xy;
  if (!inside01(kuv)) { return vec4f(0.0); }
  let a = textureSampleLevel(keyAlb, samp, kuv, 0.0);
  if (a.a < 0.002) { return vec4f(0.0); }
  let aux = textureSampleLevel(keyAux, samp, kuv, 0.0);
  let nl = hNormal(keyAux, kuv, vec2f(1.0 / 680.0, 1.0 / 260.0), 5.0);
  let ax = R3 * u.keyAxis.x + D3 * u.keyAxis.y;
  let px = R3 * -u.keyAxis.y + D3 * u.keyAxis.x;
  let n = normalize(ax * nl.x + px * nl.y + N3 * nl.z);
  let base = lin(a.rgb / a.a) * (1.0 - aux.g * 0.55);
  let c = metalColor(keyMat(), base, n, v, l, pk, lav, 1.0 - nl.z);
  return vec4f(c, a.a * select(1.0, 0.8, u.metalKind == 3u));
}
fn keyShadow(p: vec2f, l: vec3f) -> f32 {
  let lc = vec3f(dot(l, R3), dot(l, D3), max(dot(l, N3), 0.2));
  let k = keyUv(p + lc.xy / lc.z * 0.012);
  if (k.z < 0.5) { return 0.0; }
  return textureSampleLevel(keyAux, samp, k.xy, 0.0).b;
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let res = max(u.res, vec2f(1.0));
  let screen = (uv - 0.5) * vec2f(res.x / res.y, 1.0) * 2.5 * u.zoom;
  let normal = N3;
  let ray = normalize(vec3f(screen, -4.5));
  let hit = EYE - ray * (dot(EYE, normal) / dot(ray, normal));
  let p = vec2f(dot(hit, R3), dot(hit, D3));
  let v = normalize(EYE - hit);
  let l = normalize(vec3f(u.light, 1.6) - hit);
  let lav = vec2f(dot(l + v, R3), dot(l + v, D3));
  let illum = max(dot(normal, l), 0.0) * max(dot(normal, v), 0.0);

  // the studio behind the card, and the card's shadow on it
  let r2 = dot(screen, screen);
  var col = vec3f(0.010, 0.011, 0.014) + vec3f(0.02, 0.021, 0.025) * exp(-r2 * 0.9);
  let off = -normalize(u.light + vec2f(0.0, 1e-3)) * 0.05 + vec2f(0.0, 0.04);
  col *= 1.0 - 0.8 * exp(-max(sdBox(screen - off, HALF * 0.97, 0.06), 0.0) * 16.0);

  // the card's thickness, seen just past the face toward the edges
  let hitB = EYE + ray * ((-0.022 - dot(EYE, normal)) / dot(ray, normal));
  let pB = vec2f(dot(hitB, R3), dot(hitB, D3));
  // follows the face's own outline, so chamfered and notched corners keep their shape
  let uvB = cardUv(pB);
  let edgeIn = select(0.0, smoothstep(0.3, 0.7, textureSampleLevel(extAlb, samp, uvB, 0.0).a), inside01(uvB));
  if (edgeIn > 0.0) {
    let tx = vec2f(CARD_TEXEL.x * 2.0, 0.0);
    let ty = vec2f(0.0, CARD_TEXEL.y * 2.0);
    let g = -normalize(vec2f(textureSampleLevel(extAlb, samp, uvB + tx, 0.0).a - textureSampleLevel(extAlb, samp, uvB - tx, 0.0).a,
                             textureSampleLevel(extAlb, samp, uvB + ty, 0.0).a - textureSampleLevel(extAlb, samp, uvB - ty, 0.0).a) + vec2f(1e-5));
    let nE = normalize(R3 * g.x + D3 * g.y);
    col = mix(col, metalColor(keyMat(), vec3f(0.8), nE, v, l, p, lav, 1.0) * 0.8, edgeIn);
  }

  // the face, with the key's shadow on it
  var extC = exterior(p, v, l, lav, illum);
  extC = vec4f(extC.rgb * (1.0 - 0.6 * keyShadow(p, l)), extC.a);
  col = mix(col, extC.rgb, extC.a);

  // the key, resting just above the face in its slot
  let hitK = EYE + ray * ((0.012 - dot(EYE, normal)) / dot(ray, normal));
  let k = keyColor(vec2f(dot(hitK, R3), dot(hitK, D3)), v, l, lav);
  col = mix(col, k.rgb, k.a);

  // the soft glare where the light falls across the face
  let delta = p - u.light;
  let sweep = (delta.x * 0.72 + delta.y * 0.52 + sin(p.y * 4.0 + p.x * 3.0) * 0.08) / 0.36;
  col += vec3f(0.9, 0.92, 1.0) * exp(-sweep * sweep) * exp(-dot(delta * vec2f(1.05, 0.72), delta * vec2f(1.05, 0.72)) * 2.6) * 0.04 * extC.a;

  var outc = pow(aces(col * 1.1), vec3f(1.0 / 2.2));
  outc += vec3f((hash22(uv * res).x - 0.5) / 255.0);
  return vec4f(outc, 1.0);
}
`
