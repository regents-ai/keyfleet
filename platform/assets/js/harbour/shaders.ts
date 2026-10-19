/**
 * The harbour's WGSL. Each shader is prepared on its own, so the shared part is
 * written once here and placed at the head of the ones that draw the scene.
 *
 * The harbour is drawn as a blueprint: plain paper, shade hatched in ink, and a
 * gridded sea out to the horizon. The scene shaders keep an edge key in the target's alpha,
 * and the present pass inks every edge from it.
 */

/** The square of sea the ripples run on, centred on the harbour, in world units, and its cells across. */
export const RIPPLE_REACH = 13
export const RIPPLE_CELLS = 576
/** How far a ripple travels in one step, in cells: under 0.7 or the sea blows up. */
export const RIPPLE_COURANT = 0.5
/** Seconds the sea moves on in one step: with the numbers above, ripples spread about 1.4 world units a second. */
export const RIPPLE_STEP = 1 / 62
/** Ripple drops one step of the sea takes in at most. */
export const MAX_DROPS = 4

/**
 * The ripple field as the scene shaders read it: its height at any point on the
 * sea, and a ship lifted and tilted by the ripples under it.
 */
const rippleField = /* wgsl */ `
@group(0) @binding(4) var ripples: texture_2d<f32>;
@group(0) @binding(5) var rippleSampler: sampler;

fn rippleHeight(p: vec2f) -> f32 {
  let uv = (p + ${RIPPLE_REACH}.0) / ${RIPPLE_REACH * 2}.0;
  return textureSampleLevel(ripples, rippleSampler, uv, 0.0).r;
}

// A ship rides the ripples it sits on, lifted and turned to their slope. The
// slope is measured across about half a hull, so a short ripple rocks a ship
// less than a long one.
fn riding(p: vec3f, origin: vec3f) -> vec3f {
  let reach = 0.3;
  let at = origin.xz;
  let slope = clamp(
    vec2f(
      rippleHeight(at + vec2f(reach, 0.0)) - rippleHeight(at - vec2f(reach, 0.0)),
      rippleHeight(at + vec2f(0.0, reach)) - rippleHeight(at - vec2f(0.0, reach)),
    ) / (2.0 * reach),
    vec2f(-0.35),
    vec2f(0.35),
  );
  // A small turn that takes straight up to the ripple's slope: masts lean
  // downhill and the deck follows the water.
  let d = p - origin;
  let tilted = vec3f(-slope.x * d.y, slope.x * d.x + slope.y * d.z, -slope.y * d.y);
  return p + tilted + vec3f(0.0, rippleHeight(at), 0.0);
}
`

/** Keep in step with MAX_SHIPS and the five islands of every layout in sim.ts (islandsOf). */
const shared = /* wgsl */ `
struct Camera {
  viewProjection: mat4x4f,
  // Unit vector from the middle of the harbour toward the camera.
  toEye: vec3f,
}

struct Scene {
  lightViewProjection: mat4x4f,
  sunDirection: vec3f,
  time: f32,
  // The page colour the sea fades into at its edges, display-encoded.
  haze: vec3f,
  // 0 by day, 1 by night, eased between.
  night: f32,
  shipCount: u32,
  // x, z, radius, unused.
  islands: array<vec4f, 5>,
  // x, z, heading, speed from 0 to 1.
  ships: array<vec4f, 16>,
}

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var<uniform> scene: Scene;
@group(0) @binding(2) var shadowMap: texture_depth_2d;
@group(0) @binding(3) var shadowSampler: sampler_comparison;

// Paper and ink, by day and by night (display colours).
const PAPER_DAY: vec3f = vec3f(0.95, 0.96, 0.97);
const PAPER_NIGHT: vec3f = vec3f(0.11, 0.115, 0.12);
const INK_DAY: vec3f = vec3f(0.12, 0.3, 0.62);
const INK_NIGHT: vec3f = vec3f(0.8, 0.81, 0.82);

fn paper() -> vec3f {
  return mix(PAPER_DAY, PAPER_NIGHT, scene.night);
}

fn ink() -> vec3f {
  return mix(INK_DAY, INK_NIGHT, scene.night);
}

// Every face is flat: its slope comes from the screen, turned to face the camera.
fn facetNormal(p: vec3f) -> vec3f {
  let n = normalize(cross(dpdx(p), dpdy(p)));
  return select(-n, n, dot(n, camera.toEye) > 0.0);
}

// 1 in sunlight, 0 in shadow, with a hard edge.
fn sunShadow(p: vec3f, n: vec3f) -> f32 {
  let clip = scene.lightViewProjection * vec4f(p + n * 0.02, 1.0);
  let ndc = clip.xyz / clip.w;
  let uv = vec2f(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
  if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0)) || ndc.z > 1.0) {
    return 1.0;
  }
  return textureSampleCompareLevel(shadowMap, shadowSampler, uv, ndc.z - 0.0012);
}

// What the present pass draws its outlines from: a value that changes across
// every edge worth inking, kept in the scene target's alpha.
fn edgeKey(n: vec3f, material: u32, height: f32) -> f32 {
  return 0.15 + 0.3 * (dot(n, vec3f(0.31, 0.83, 0.47)) * 0.5 + 0.5) + 0.05 * f32(material % 8u)
    + 0.04 * clamp(height, 0.0, 3.0);
}

// The sea's own key: no outline inside the water, only where it meets land.
const WATER_KEY: f32 = 0.05;

// Diagonal ink strokes in screen space, for shade.
fn hatch(pixel: vec2f) -> f32 {
  return step(0.62, fract((pixel.x + pixel.y) / 7.0));
}

// Same sum as waveHeight in sim.ts.
fn waveHeight(p: vec2f, t: f32) -> f32 {
  return 0.045 * sin(0.9 * p.x + 0.6 * p.y + 1.1 * t)
    + 0.03 * sin(-0.5 * p.x + 1.3 * p.y + 1.7 * t + 1.3)
    + 0.018 * sin(1.9 * p.x - 1.1 * p.y + 2.3 * t);
}

// Sails belly forward and flags ripple along their length.
fn swayed(position: vec3f, material: u32, sway: f32, phase: f32) -> vec3f {
  var p = position;
  let t = scene.time;
  if (material == 10u) {
    p.x += sway * (0.075 + 0.02 * sin(t * 1.7 + phase));
  }
  if (material == 11u) {
    p.z += sway * 0.07 * sin(t * 5.0 - p.x * 9.0 + phase);
  }
  return p;
}
`

/**
 * Islands, buildings, ships and smoke: every mesh vertex names its material.
 * Sails and pennants keep their agent's colour, and lit windows and the forge
 * glow at night. Ships also ride the ripples.
 */
const parts = (ride: boolean) => /* wgsl */ `${shared}${ride ? rippleField : ""}
struct PartInput {
  @location(0) position: vec3f,
  @location(1) material: f32,
  @location(2) sway: f32,
  @location(3) world0: vec4f,
  @location(4) world1: vec4f,
  @location(5) world2: vec4f,
  @location(6) world3: vec4f,
  // rgb: the agent's colour (display), w: a phase so no two ships move alike.
  @location(7) style: vec4f,
}

struct PartVarying {
  @builtin(position) clip: vec4f,
  @location(0) world: vec3f,
  @location(1) @interpolate(flat, either) material: u32,
  @location(2) @interpolate(flat, either) style: vec4f,
}

@vertex
fn vs_main(input: PartInput) -> PartVarying {
  let model = mat4x4f(input.world0, input.world1, input.world2, input.world3);
  let material = u32(input.material + 0.5);
  let local = swayed(input.position, material, input.sway, input.style.w);
  var output: PartVarying;
  let world = (model * vec4f(local, 1.0)).xyz;
  output.world = ${ride ? "riding(world, input.world3.xyz)" : "world"};
  output.material = material;
  output.style = input.style;
  output.clip = camera.viewProjection * vec4f(output.world, 1.0);
  return output;
}

@fragment
fn fs_main(input: PartVarying) -> @location(0) vec4f {
  let n = facetNormal(input.world);
  let facing = max(dot(n, scene.sunDirection), 0.0) * sunShadow(input.world, n);
  var colour = mix(paper(), ink(), hatch(input.clip.xy) * (1.0 - smoothstep(0.15, 0.35, facing)) * 0.55);
  if (input.material == 10u || input.material == 11u) {
    colour = mix(input.style.rgb, paper(), 0.15);
  }
  if (input.material == 7u || input.material == 8u) {
    colour = mix(colour, vec3f(1.0, 0.76, 0.42), scene.night);
  }
  return vec4f(colour, edgeKey(n, input.material, input.world.y));
}
`

export const partsWgsl = parts(false)
export const shipWgsl = parts(true)

/**
 * The sea seen from low down: a grid riding the swell, turned to lie square to
 * the page, soundings rolling out from each beach, wakes in ink, ripples drawn
 * as contours of the ripple field, and shadows hatched. Far out it melts into
 * the sky.
 */
export const seaWgsl = /* wgsl */ `${shared}${rippleField}
struct WaterVarying {
  @builtin(position) clip: vec4f,
  @location(0) world: vec3f,
}

// Ripple heights between two ink lines, and the most lines one ripple draws on either side of still water.
const RIPPLE_LEVEL: f32 = 0.0045;
const RIPPLE_LINES: f32 = 3.0;

@vertex
fn vs_main(@location(0) position: vec3f) -> WaterVarying {
  var output: WaterVarying;
  output.world = vec3f(position.x, waveHeight(position.xz, scene.time) + rippleHeight(position.xz), position.z);
  output.clip = camera.viewProjection * vec4f(output.world, 1.0);
  return output;
}

// The short V a moving hull leaves behind it.
fn wakes(p: vec2f) -> f32 {
  var foam = 0.0;
  for (var i = 0u; i < min(scene.shipCount, 16u); i++) {
    let ship = scene.ships[i];
    let forward = vec2f(cos(ship.z), sin(ship.z));
    let offset = p - ship.xy;
    let behind = -dot(offset, forward);
    let side = dot(offset, vec2f(-forward.y, forward.x));
    if (behind < -0.4 || behind > 1.6 || abs(side) > 0.8) {
      continue;
    }
    let fade = (1.0 - smoothstep(0.0, 1.6, behind)) * smoothstep(-0.4, -0.05, behind) * ship.w;
    let arm = abs(abs(side) - (0.08 + max(behind, 0.0) * 0.38));
    let edge = 1.0 - smoothstep(0.01, 0.05 + behind * 0.04, arm);
    let hull = 1.0 - smoothstep(0.1, 0.26, length(offset));
    foam += edge * fade * 0.7 + hull * 0.3 * ship.w;
  }
  return foam;
}

@fragment
fn fs_main(input: WaterVarying) -> @location(0) vec4f {
  let p = input.world;
  var shore = 100.0;
  for (var i = 0u; i < 5u; i++) {
    let island = scene.islands[i];
    shore = min(shore, length(p.xz - island.xy) - island.z);
  }
  // Lines keep one width on screen: each is measured against its own step per pixel.
  let grid = vec2f(p.x - p.z, p.x + p.z) * 0.70710678 / 0.7;
  let gridStep = fwidth(grid);
  let shoreStep = fwidth(shore);
  // Ripples as a chart's contours: a line at each step of height, crests in full
  // ink and troughs fainter, still water left blank.
  let level = rippleHeight(p.xz) / RIPPLE_LEVEL;
  let levelStep = max(fwidth(level), 1e-4);

  let cell = abs(fract(grid - 0.5) - 0.5) / max(gridStep, vec2f(1e-4));
  let gridLine = 1.0 - min(min(cell.x, cell.y), 1.0);
  let sounding = max(shore, 0.0) / 0.45 - scene.time * 0.25;
  let ring = abs(fract(sounding - 0.5) - 0.5) / max(shoreStep / 0.45, 1e-4);
  let ringLine = (1.0 - min(ring, 1.0)) * (1.0 - smoothstep(1.5, 4.0, shore)) * step(0.0, shore);
  let coast = 1.0 - min(abs(shore) / max(shoreStep, 1e-4), 1.0);
  let wake = smoothstep(0.3, 0.5, wakes(p.xz));
  let line = round(level);
  let contour = 1.0 - min(abs(level - line) / levelStep / 1.5, 1.0);
  let counted = step(0.5, abs(line)) * step(abs(line), RIPPLE_LINES + 0.5);
  let ripple = contour * counted * select(0.7, 1.0, line > 0.0) * step(0.0, shore);
  let hatched = hatch(input.clip.xy) * (1.0 - sunShadow(p, vec3f(0.0, 1.0, 0.0))) * 0.55;
  let drawn = mix(paper(), ink(), max(max(max(gridLine * 0.3, ringLine * 0.8), ripple), max(max(coast, wake), hatched)));

  // Far water melts into the page.
  let far = smoothstep(16.0, 90.0, length(p.xz));
  return vec4f(mix(drawn, scene.haze, far), WATER_KEY);
}
`

/** Depth from the sun, for every mesh that casts a shadow. Ships ride the ripples here too. */
const shadow = (ride: boolean) => /* wgsl */ `${ride ? rippleField : ""}
struct Scene {
  lightViewProjection: mat4x4f,
  sunDirection: vec3f,
  time: f32,
  haze: vec3f,
  night: f32,
  shipCount: u32,
  islands: array<vec4f, 5>,
  ships: array<vec4f, 16>,
}

@group(0) @binding(1) var<uniform> scene: Scene;

struct ShadowInput {
  @location(0) position: vec3f,
  @location(1) material: f32,
  @location(2) sway: f32,
  @location(3) world0: vec4f,
  @location(4) world1: vec4f,
  @location(5) world2: vec4f,
  @location(6) world3: vec4f,
  @location(7) style: vec4f,
}

@vertex
fn vs_main(input: ShadowInput) -> @builtin(position) vec4f {
  let model = mat4x4f(input.world0, input.world1, input.world2, input.world3);
  var p = input.position;
  let material = u32(input.material + 0.5);
  if (material == 10u) {
    p.x += input.sway * (0.075 + 0.02 * sin(scene.time * 1.7 + input.style.w));
  }
  let world = (model * vec4f(p, 1.0)).xyz;
  return scene.lightViewProjection * vec4f(${ride ? "riding(world, input.world3.xyz)" : "world"}, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4f {
  return vec4f(0.0);
}
`

export const shadowWgsl = shadow(false)
export const shipShadowWgsl = shadow(true)

/**
 * One step of the ripples: each cell of sea moves toward its neighbours, as
 * water does, and keeps a little less of its height each time. The islands are
 * walls: their beaches soak a wave up rather than send it back, so the water
 * behind an island stays still apart from what bends round it. The sea's edge
 * soaks up everything, and new drops land in the first step after a click.
 */
export const rippleStepWgsl = /* wgsl */ `
struct Ripples {
  // x, z, radius, unused.
  islands: array<vec4f, 5>,
  // x, z, height, unused; an empty slot has no height.
  drops: array<vec4f, ${MAX_DROPS}>,
}

@group(0) @binding(0) var<uniform> sea: Ripples;
// r: height now, g: height a step ago.
@group(0) @binding(1) var field: texture_2d<f32>;

const CELLS: i32 = ${RIPPLE_CELLS};
const REACH: f32 = ${RIPPLE_REACH}.0;
const CELL: f32 = ${(RIPPLE_REACH * 2) / RIPPLE_CELLS};
// How far a wave travels each step, in cells, squared.
const COURANT: f32 = ${RIPPLE_COURANT ** 2};
const KEEP: f32 = 0.996;
// A drop lands as a few rings at once, this far apart and spread over this
// much sea, in world units, so it leaves as a short train of ripples.
const DROP_GAP: f32 = 0.5;
const DROP_SPREAD: f32 = 0.32;

fn heightAt(cell: vec2i) -> f32 {
  return textureLoad(field, clamp(cell, vec2i(0), vec2i(CELLS - 1)), 0).r;
}

@fragment
fn fs_main(@builtin(position) position: vec4f) -> @location(0) vec4f {
  let cell = vec2i(position.xy);
  let p = (vec2f(cell) + 0.5) * CELL - REACH;
  var shore = 100.0;
  for (var i = 0u; i < 5u; i++) {
    let island = sea.islands[i];
    shore = min(shore, length(p - island.xy) - island.z);
  }
  if (shore <= 0.0) {
    return vec4f(0.0);
  }

  let here = textureLoad(field, cell, 0);
  let around = heightAt(cell + vec2i(1, 0)) + heightAt(cell - vec2i(1, 0))
    + heightAt(cell + vec2i(0, 1)) + heightAt(cell - vec2i(0, 1));
  let edge = REACH - max(abs(p.x), abs(p.y));
  let keep = KEEP * mix(0.9, 1.0, smoothstep(0.0, 1.5, edge)) * mix(0.93, 1.0, smoothstep(0.0, 0.4, shore));
  var next = (2.0 * here.r - here.g + COURANT * (around - 4.0 * here.r)) * keep;

  // A drop lifts the water without setting it moving, so it falls back as rings.
  var lift = 0.0;
  for (var i = 0u; i < ${MAX_DROPS}u; i++) {
    let drop = sea.drops[i];
    let away = length(p - drop.xy);
    lift += drop.z * cos(away * 6.2831853 / DROP_GAP) * exp(-away * away / (2.0 * DROP_SPREAD * DROP_SPREAD));
  }
  return vec4f(next + lift, here.r * keep + lift, 0.0, 1.0);
}
`

/** Lays the scene on the page: ink on every edge, and a soft vignette. */
export const presentWgsl = /* wgsl */ `
struct Present {
  resolution: vec2f,
  vignette: f32,
  // Outline width in pixels.
  line: f32,
  // The outline colour (display).
  ink: vec3f,
}

@group(0) @binding(0) var<uniform> present: Present;
@group(0) @binding(1) var sceneColor: texture_2d<f32>;
@group(0) @binding(2) var linearSampler: sampler;

// The step in the scene's edge key that counts as an edge.
const EDGE: f32 = 0.015;

fn keyAt(uv: vec2f) -> f32 {
  return textureSampleLevel(sceneColor, linearSampler, uv, 0.0).a;
}

@fragment
fn fs_main(@builtin(position) position: vec4f) -> @location(0) vec4f {
  let uv = position.xy / present.resolution;
  let offset = present.line / present.resolution;
  let across = abs(keyAt(uv + vec2f(offset.x, 0.0)) - keyAt(uv - vec2f(offset.x, 0.0)));
  let down = abs(keyAt(uv + vec2f(0.0, offset.y)) - keyAt(uv - vec2f(0.0, offset.y)));
  let edge = smoothstep(EDGE, EDGE * 2.0, max(across, down));
  let color = mix(textureSampleLevel(sceneColor, linearSampler, uv, 0.0).rgb, present.ink, edge);
  let centred = (uv - 0.5) * vec2f(present.resolution.x / present.resolution.y, 1.0);
  let vignette = 1.0 - present.vignette * smoothstep(0.4, 1.2, length(centred));
  return vec4f(color * vignette, 1.0);
}
`
