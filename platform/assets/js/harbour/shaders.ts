/**
 * The harbour's WGSL. Each shader is prepared on its own, so the shared part is
 * written once here and placed at the head of the ones that draw the scene.
 *
 * The harbour is drawn as the crew's chart: warm paper, black hairlines, shade
 * laid in a flat grey band and one orange for the route the lead ship sails. By
 * night the paper and ink swap. The scene shaders keep an edge key in the
 * target's alpha, and the present pass inks every edge from it, then lays the
 * chart over the open sea: a ruled dial down the left, a fan of lines running
 * into it, rows of crew icons round each place and the lead ship's route.
 */

/** The chart's colours, by day and by night (display colours, 0 to 1). */
type Colour = readonly [number, number, number]

export const PALETTE: Readonly<Record<"paperDay" | "paperNight" | "inkDay" | "inkNight" | "bandDay" | "bandNight" | "accent", Colour>> = {
  paperDay: [0.894, 0.878, 0.8],
  paperNight: [0.078, 0.078, 0.078],
  inkDay: [0.078, 0.078, 0.078],
  inkNight: [0.894, 0.878, 0.8],
  bandDay: [0.839, 0.827, 0.765],
  bandNight: [0.157, 0.157, 0.149],
  accent: [0.91, 0.329, 0.102],
}

const vec3 = (colour: readonly number[]) => `vec3f(${colour.join(", ")})`

/**
 * The edge key of open water, which the sky shares, so the sea melts into the
 * sky with no line at the horizon and the chart knows open sea from land.
 */
export const WATER_KEY = 0.05

/** How far outside each place's beach its row of crew icons runs, in world units. */
export const ICON_GAP = 1.95
/**
 * The great circles round the whole harbour: the first one's radius, how much
 * wider each next one is, and how many of them, the first few dashed rows of
 * crew icons and the rest faint lines.
 */
export const CIRCLE_FIRST = 9.5
export const CIRCLE_GROWTH = 1.38
export const CIRCLE_ROWS = 2
const CIRCLES = 4
/** Crew icons the chart shows at most. */
export const MAX_MARKS = 96

/**
 * The crew icons, eight cells square, "#" in ink: a boxed N, D and M, a slashed
 * circle, a little robot, a head and a stepped block.
 */
const GLYPH_ART = [
  ["########", "#......#", "#.#..#.#", "#.##.#.#", "#.#.##.#", "#.#..#.#", "#......#", "########"],
  ["########", "#......#", "#.###..#", "#.#..#.#", "#.#..#.#", "#.###..#", "#......#", "########"],
  ["########", "#......#", "#.#..#.#", "#.####.#", "#.#..#.#", "#.#..#.#", "#......#", "########"],
  ["..####..", ".#....##", "#....#.#", "#...#..#", "#..#...#", "#.#....#", "##....#.", "..####.."],
  ["........", "..#..#..", ".######.", "##.##.##", "########", ".######.", ".#....#.", "........"],
  ["..####..", ".######.", "########", "#.####.#", "########", ".######.", "..#..#..", "........"],
  ["######..", "######..", "##..##..", "######..", "##..###.", "##..###.", "........", "........"],
]

export const GLYPH_COUNT = GLYPH_ART.length

/** Each icon as two words, four rows of eight bits each, the top row in the low byte and its left cell in the high bit. */
const glyphWords = GLYPH_ART.flatMap(rows =>
  [0, 4].map(first =>
    rows
      .slice(first, first + 4)
      .reduce((word, row, index) => (word | (Number.parseInt(row.replaceAll("#", "1").replaceAll(".", "0"), 2) << (index * 8))) >>> 0, 0),
  ),
)

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

// Paper, ink and the grey band, by day and by night, and the one orange.
const PAPER_DAY: vec3f = ${vec3(PALETTE.paperDay)};
const PAPER_NIGHT: vec3f = ${vec3(PALETTE.paperNight)};
const INK_DAY: vec3f = ${vec3(PALETTE.inkDay)};
const INK_NIGHT: vec3f = ${vec3(PALETTE.inkNight)};
const BAND_DAY: vec3f = ${vec3(PALETTE.bandDay)};
const BAND_NIGHT: vec3f = ${vec3(PALETTE.bandNight)};
const ACCENT: vec3f = ${vec3(PALETTE.accent)};

fn paper() -> vec3f {
  return mix(PAPER_DAY, PAPER_NIGHT, scene.night);
}

fn ink() -> vec3f {
  return mix(INK_DAY, INK_NIGHT, scene.night);
}

fn band() -> vec3f {
  return mix(BAND_DAY, BAND_NIGHT, scene.night);
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
const WATER_KEY: f32 = ${WATER_KEY};

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
 * Faces are paper with their shade in the grey band, sails are solid ink and
 * pennants keep their agent's colour; lit windows and the forge glow orange at
 * night. Ships also ride the ripples.
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
  var colour = mix(paper(), band(), 1.0 - smoothstep(0.15, 0.35, facing));
  if (input.material == 10u) {
    colour = ink();
  }
  if (input.material == 11u) {
    colour = input.style.rgb;
  }
  if (input.material == 7u || input.material == 8u) {
    colour = mix(colour, ACCENT, scene.night);
  }
  return vec4f(colour, edgeKey(n, input.material, input.world.y));
}
`

export const partsWgsl = parts(false)
export const shipWgsl = parts(true)

/**
 * The sea seen from low down: plain paper riding the swell, a dashed row round
 * each place for its crew icons, faint great circles round the harbour, one
 * contour off every beach, wakes in ink, ripples drawn as contours of the
 * ripple field, and shadows laid in the grey band. Far out it melts into the sky.
 */
export const seaWgsl = /* wgsl */ `${shared}${rippleField}
struct WaterVarying {
  @builtin(position) clip: vec4f,
  @location(0) world: vec3f,
}

// Ripple heights between two ink lines, and the most lines one ripple draws on either side of still water.
const RIPPLE_LEVEL: f32 = 0.0045;
const RIPPLE_LINES: f32 = 3.0;
// The icon rows: how far outside each beach, and the length of one dash and its gap.
const ICON_GAP: f32 = ${ICON_GAP};
const DASH: f32 = 0.22;
// The great circles: the first one's radius, how much wider each next one is,
// how many are dashed rows, and how many there are.
const CIRCLE_FIRST: f32 = ${CIRCLE_FIRST};
const CIRCLE_GROWTH: f32 = ${CIRCLE_GROWTH};
const CIRCLE_ROWS: f32 = ${CIRCLE_ROWS}.0;
const CIRCLES: f32 = ${CIRCLES}.0;

// 1 on a line where \`distance\` is zero, one pixel wide whatever the distance's scale.
fn hairline(distance: f32) -> f32 {
  return 1.0 - min(abs(distance) / max(fwidth(distance), 1e-4), 1.0);
}

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
  // The places come first in the islands: each has its dashed row, and the
  // first great circles round the harbour are rows too.
  var rows = 0.0;
  for (var i = 0u; i < 3u; i++) {
    let island = scene.islands[i];
    let offset = p.xz - island.xy;
    let ringRadius = island.z + ICON_GAP;
    let along = atan2(offset.y, offset.x) * ringRadius;
    rows = max(rows, hairline(length(offset) - ringRadius) * step(fract(along / DASH), 0.5));
  }
  let reach = length(p.xz);
  let around = atan2(p.z, p.x);
  var circles = 0.0;
  for (var k = 0.0; k < CIRCLES; k += 1.0) {
    let circleRadius = CIRCLE_FIRST * pow(CIRCLE_GROWTH, k);
    let circle = hairline(reach - circleRadius);
    if (k < CIRCLE_ROWS) {
      rows = max(rows, circle * step(fract(around * circleRadius / DASH), 0.5));
    } else {
      circles = max(circles, circle);
    }
  }
  // Ripples as a chart's contours: a line at each step of height, crests in full
  // ink and troughs fainter, still water left blank.
  let level = rippleHeight(p.xz) / RIPPLE_LEVEL;
  let levelStep = max(fwidth(level), 1e-4);
  let line = round(level);
  let contour = 1.0 - min(abs(level - line) / levelStep / 1.5, 1.0);
  let counted = step(0.5, abs(line)) * step(abs(line), RIPPLE_LINES + 0.5);
  let ripple = contour * counted * select(0.7, 1.0, line > 0.0) * step(0.0, shore);
  let coast = hairline(shore);
  let offshore = hairline(shore - 0.3) * step(0.0, shore);
  let wake = smoothstep(0.3, 0.5, wakes(p.xz));
  let shaded = 1.0 - sunShadow(p, vec3f(0.0, 1.0, 0.0));
  let inked = max(max(max(coast, wake), ripple), max(rows * 0.85, max(offshore * 0.45, circles * 0.22)));
  let drawn = mix(mix(paper(), band(), shaded * 0.8), ink(), inked);

  // Far water melts into the page.
  let far = smoothstep(16.0, 90.0, reach);
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

/**
 * Lays the scene on the page with ink on every edge, then draws the chart over
 * the open sea and sky, never over land or ships: a broad ruled dial standing
 * on the page's left edge (its bottom edge on a tall page), its band holding
 * rows of bars that change now and then, a fan of fine lines running into a
 * black node on it, the crew icons on their rows, and the lead ship's route from
 * the node in orange.
 */
export const presentWgsl = /* wgsl */ `
struct Present {
  resolution: vec2f,
  // Hairline width in pixels.
  line: f32,
  // Pixels in one cell of a crew icon.
  cell: f32,
  // The chart's ink, paper and band (display).
  ink: vec3f,
  time: f32,
  paper: vec3f,
  markCount: u32,
  band: vec3f,
  // 1 while there is a lead ship to draw a route to.
  leading: f32,
  // The lead ship on the canvas, in pixels.
  lead: vec2f,
  // x and y in pixels, the icon, and its tone: 0 ink, 1 grey.
  marks: array<vec4f, ${MAX_MARKS}>,
}

@group(0) @binding(0) var<uniform> present: Present;
@group(0) @binding(1) var sceneColor: texture_2d<f32>;
@group(0) @binding(2) var linearSampler: sampler;

// The step in the scene's edge key that counts as an edge.
const EDGE: f32 = 0.015;
const ACCENT: vec3f = ${vec3(PALETTE.accent)};
// Where the fan meets the dial, as an angle round the dial's middle, and its lines.
const NODE_ANGLE: f32 = -0.118;
const FAN_LINES: u32 = 26u;

var<private> GLYPHS: array<u32, ${glyphWords.length}> = array<u32, ${glyphWords.length}>(${glyphWords.map(word => `${word}u`).join(", ")});

fn keyAt(uv: vec2f) -> f32 {
  return textureSampleLevel(sceneColor, linearSampler, uv, 0.0).a;
}

fn hash(n: f32) -> f32 {
  return fract(sin(n * 91.345) * 47453.5453);
}

// 1 on a line \`gap\` pixels away, \`width\` pixels wide, with a soft pixel at its edge.
fn stroke(gap: f32, width: f32) -> f32 {
  return 1.0 - smoothstep(width * 0.5, width * 0.5 + 1.0, gap);
}

// Whether a cell of an icon is inked; cells run 0 to 7 across and down.
fn glyphAt(glyph: u32, cell: vec2i) -> f32 {
  let word = GLYPHS[glyph * 2u + u32(cell.y) / 4u];
  let bit = u32(cell.y % 4) * 8u + 7u - u32(cell.x);
  return f32((word >> bit) & 1u);
}

@fragment
fn fs_main(@builtin(position) position: vec4f) -> @location(0) vec4f {
  let px = position.xy;
  let uv = px / present.resolution;
  let offset = present.line / present.resolution;
  let across = abs(keyAt(uv + vec2f(offset.x, 0.0)) - keyAt(uv - vec2f(offset.x, 0.0)));
  let down = abs(keyAt(uv + vec2f(0.0, offset.y)) - keyAt(uv - vec2f(0.0, offset.y)));
  let edge = smoothstep(EDGE, EDGE * 2.0, max(across, down));
  var color = mix(textureSampleLevel(sceneColor, linearSampler, uv, 0.0).rgb, present.ink, edge);

  // Open sea and sky share the water's key; anything else is land or a ship.
  let open = select(0.0, 1.0, keyAt(uv) < ${WATER_KEY * 2});
  let lw = present.line;
  let size = present.resolution;
  // The dial stands on the left edge of a wide page and the bottom edge of a
  // tall one: q is a pixel measured out from that edge and along it, and
  // \`along\` is the edge's length.
  let tall = size.y > size.x;
  let q = select(px, vec2f(size.y - px.y, px.x), tall);
  let along = select(size.y, size.x, tall);
  let unit = min(along, select(size.x, size.y, tall) * 0.9);

  // The dial, its middle off the page.
  let centre = vec2f(-0.55 * unit, 0.5 * along);
  let radius = 0.85 * unit;
  let width = 0.05 * unit;
  let fromCentre = q - centre;
  let depth = length(fromCentre) - radius;
  let angle = atan2(fromCentre.y, fromCentre.x);
  let inBand = step(0.0, depth) * step(depth, width);
  color = mix(color, present.band, inBand * open);
  let rims = max(stroke(abs(depth), lw), stroke(abs(depth - width), lw));
  let tickStep = 0.011;
  let tickIndex = round(angle / tickStep);
  let tickLength = select(0.012, 0.028, i32(tickIndex) % 5 == 0) * unit;
  let tick = stroke(abs(angle - tickIndex * tickStep) * (radius + depth), lw) * step(width, depth) * step(depth, width + tickLength);
  // Rows of bars in clusters of up to six, each row taking a new length now and then.
  let rowStep = 0.0105;
  let row = floor(angle / rowStep);
  let inRow = fract(angle / rowStep);
  let cluster = floor(row / 8.0);
  let shown = step(0.4, hash(cluster + 0.37)) * step(row - cluster * 8.0, 5.5) * step(0.2, inRow) * step(inRow, 0.78);
  let beat = floor(present.time * 0.4 + hash(row + 5.1) * 3.0);
  let barLength = width * (0.2 + 0.62 * hash(row * 1.37 + beat * 7.1));
  let bar = shown * step(width * 0.12, depth) * step(depth, width * 0.12 + barLength);
  color = mix(color, present.ink, max(max(rims, tick), bar) * open);

  // The fan: fine lines from the dial's edge of the page, swaying a little,
  // drawn together into the node.
  let nodeQ = centre + radius * vec2f(cos(NODE_ANGLE), sin(NODE_ANGLE));
  var fan = 0.0;
  if (q.x < nodeQ.x) {
    let t = q.x / nodeQ.x;
    for (var i = 0u; i < FAN_LINES; i++) {
      let f = f32(i);
      let start = along * (-0.35 + 1.7 * (f + 0.6 * hash(f + 3.0)) / f32(FAN_LINES)) + sin(present.time * 0.25 + f * 1.7) * 0.02 * along;
      let rise = start - nodeQ.y;
      let y = nodeQ.y + rise * (1.0 - t) * (1.0 - t);
      let slope = -2.0 * rise * (1.0 - t) / nodeQ.x;
      fan = max(fan, stroke(abs(q.y - y) / sqrt(1.0 + slope * slope), 0.0));
    }
  }
  color = mix(color, present.ink, fan * 0.55 * open);
  let node = select(nodeQ, vec2f(nodeQ.y, size.y - nodeQ.x), tall);

  // The crew icons on their rows, ink or grey.
  let grey = mix(present.paper, present.ink, 0.45);
  for (var i = 0u; i < min(present.markCount, ${MAX_MARKS}u); i++) {
    let mark = present.marks[i];
    let cell = floor((px - floor(mark.xy)) / present.cell) + 4.0;
    if (any(cell < vec2f(0.0)) || any(cell > vec2f(7.0))) {
      continue;
    }
    color = mix(color, select(present.ink, grey, mark.w > 0.5), glyphAt(u32(mark.z), vec2i(cell)) * open);
  }

  // The node, and the lead ship's route out of it: dashed orange, a box at every
  // stop along the way and a box round the ship.
  color = mix(color, present.ink, step(max(abs(px.x - node.x), abs(px.y - node.y)), 0.012 * unit));
  if (present.leading > 0.5) {
    let along = present.lead - node;
    let span = length(along);
    let toward = along / max(span, 1e-3);
    let s = dot(px - node, toward);
    let side = abs(dot(px - node, vec2f(-toward.y, toward.x)));
    let dash = step(fract(s / (0.016 * unit)), 0.55) * step(0.014 * unit, s) * step(s, span - 0.024 * unit);
    var route = stroke(side, lw * 1.5) * dash;
    let stop = 0.09 * unit;
    let at = node + toward * clamp(round(s / stop), 1.0, floor(span / stop)) * stop;
    let box = abs(max(abs(px.x - at.x), abs(px.y - at.y)) - 0.008 * unit);
    route = max(route, stroke(box, lw * 1.2) * step(stop * 1.5, span));
    let shipBox = abs(max(abs(px.x - present.lead.x), abs(px.y - present.lead.y)) - 0.022 * unit);
    route = max(route, stroke(shipBox, lw * 1.5));
    color = mix(color, ACCENT, route);
  }
  return vec4f(color, 1.0);
}
`
