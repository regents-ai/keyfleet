/**
 * The Worldline's three passes over a clear canvas with premultiplied alpha,
 * so the page's own ground shows through: the trails, each a ribbon with a
 * soft glow, and the line over them; the beads riding the trails; then every
 * event's mark on them and the head over all. Each places a point of a trail
 * by the same sum as `project` in trails.ts: a helix turning around the line,
 * seen a little from above, curling at each event. The side behind the line
 * is drawn fainter and finer, the side in front brighter and fuller.
 */

const shared = /* wgsl */ `
struct Params {
  // Width and height in device pixels, device pixels per CSS pixel, and now,
  // in seconds from the anchor.
  size: vec4f,
  // The time at the left edge, seconds across one device pixel, the orbit's
  // turn in radians, and the latest time shown yet as the picture reveals.
  view: vec4f,
  // The point in focus by its index (-1 for none) and how far it stands
  // out, 0..1; the earliest time that just arrived and how near the head it
  // still is, 1 at the head to 0 settled.
  focus: vec4f,
  // How strong the glow is, and how faint the far side of a trail.
  mood: vec4f,
  line: vec4f,
  workspace: vec4f,
  code: vec4f,
  notebooks: vec4f,
  chat: vec4f,
  opened: vec4f,
  closed: vec4f,
  poll: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

const REACH = 0.44;
const ELEVATION = 0.38;
const CURL_TURN = 2.2;
const CURL_SHARE = 1.0 / CURL_TURN;
const SETTLE = 0.15;
const TAU = 6.2831853;

fn tone(index: f32) -> vec3f {
  switch u32(index + 0.5) {
    case 0u: { return params.line.rgb; }
    case 1u: { return params.workspace.rgb; }
    case 2u: { return params.code.rgb; }
    case 3u: { return params.notebooks.rgb; }
    case 4u: { return params.chat.rgb; }
    case 5u: { return params.opened.rgb; }
    case 6u: { return params.closed.rgb; }
    default: { return params.poll.rgb; }
  }
}

// How wide an event's curl is drawn, in device pixels: its trail's widest
// of the reach, or less when its next event, gap seconds on, stands close
// on the picture.
fn curl(gap: f32, widest: f32) -> f32 {
  return min(widest * REACH * params.size.y, CURL_SHARE * gap / params.view.y);
}

// How far the line runs on, in device pixels, while the curl coil wide of
// an event at time t, its next event gap seconds on, turns once around.
fn across(t: f32, gap: f32, coil: f32) -> f32 {
  return min(CURL_TURN * coil, max(0.0, min(gap, params.size.w - t)) / params.view.y);
}

// How far a curl that turns once over wide device pixels has turned after
// pixels on, in radians.
fn swirl(after: f32, wide: f32) -> f32 {
  return TAU * clamp(after / max(wide, 0.001), 0.0, 1.0);
}

// How far out a trail runs at time t, 0..1: all the way, until it settles
// into the head over the last SETTLE of the picture before now.
fn settled(t: f32) -> f32 {
  return smoothstep(0.0, 1.0, (params.size.w - t) / params.view.y / (SETTLE * params.size.x));
}

// A point of a trail at time t, on a curl coil device pixels wide turned psi
// from its foot, every curl rising from the trail to face the reader with
// its tip up, both drawn in as the trail settles into the head: where it
// stands in device pixels, and how near the reader it is, -1..1. shape: how
// far out the trail runs, where around the line it stood at the anchor, how
// far its turns lean along the line, and how fast it turns as the picture
// orbits; turn: the seconds it takes to go once around the line.
fn place(t: f32, psi: f32, coil: f32, shape: vec4f, turn: f32) -> vec3f {
  let out = settled(t);
  let reach = shape.x * REACH * params.size.y * out;
  let curled = coil * out;
  let angle = TAU * t / turn + shape.y + params.view.z * shape.w;
  let s = sin(angle);
  let c = cos(angle);
  let up = reach * c;
  let deep = reach * s * cos(shape.z);
  let x = (t - params.view.x) / params.view.y + reach * s * sin(shape.z) + curled * sin(psi);
  let y = params.size.y * 0.5 - (up * cos(ELEVATION) - deep * sin(ELEVATION)) - curled * (1.0 - cos(psi));
  var near = 0.0;
  if (reach > 0.0) {
    near = (up * sin(ELEVATION) + deep * cos(ELEVATION)) / reach;
  }
  return vec3f(x, y, near);
}

// Where the head stands, at now on the line.
fn head() -> vec2f {
  return place(params.size.w, 0.0, 0.0, vec4f(0.0), 1.0).xy;
}

fn clip(at: vec2f) -> vec4f {
  return vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
}

// How strongly a point is drawn for how near it is: the far side faint.
fn depth(near: f32) -> f32 {
  return mix(params.mood.y, 1.0, near * 0.5 + 0.5);
}

// How full a point is drawn for how near it is: the far side fine.
fn fullness(near: f32) -> f32 {
  return mix(0.6, 1.2, near * 0.5 + 0.5);
}

// A round point radius device pixels wide with a glow spread device pixels
// on, at offset from its middle.
fn shine(offset: vec2f, radius: f32, spread: f32, glow: f32) -> f32 {
  let distance = length(offset);
  let core = 1.0 - smoothstep(radius - 0.75, radius + 0.75, distance);
  let beyond = max(distance - radius, 0.0) / spread;
  return core + exp(-beyond * beyond) * glow * (1.0 - core);
}
`

/** Pieces each stretch of trail is cut into: a strip of (SEGMENTS + 1) * 2 vertices. */
export const SEGMENTS = 48

/**
 * The trails and the line, one ribbon per stretch of trail between two
 * events, or from the last one on into the head at now. The line itself runs
 * from past the left edge to now.
 */
export const trailsWgsl = /* wgsl */ `
${shared}

const SEGMENTS = ${SEGMENTS}u;

struct Ribbon {
  @builtin(position) position: vec4f,
  // Distance from the middle of the line, in device pixels, either side.
  @location(0) across: f32,
  // Half the solid line's width, in device pixels.
  @location(1) half: f32,
  @location(2) color: vec3f,
  @location(3) strength: f32,
  // How strong its glow is against the picture's own.
  @location(4) glow: f32,
}

// A point u (0..1) of the stretch, held at the latest time revealed yet.
// a: the start's and the end's time, and the seconds from the start on to
// its trail's next event; b: the trail's shape; c: its colour, width,
// strength, and 1 when it runs on to now, 2 when it is the line itself; d:
// the seconds its trail takes to turn once around the line, and its widest
// curl. The stretch's pieces go to its event's curl and to the run on from
// it as far as each is long, a tenth to six tenths to the curl.
fn stretch(a: vec4f, b: vec4f, c: vec4f, d: vec4f, u: f32) -> vec3f {
  var start = a.x;
  var stop = a.y;
  if (c.w > 0.5) {
    stop = params.size.w;
  }
  if (c.w > 1.5) {
    start = params.view.x - params.size.x * params.view.y;
  }
  let coil = curl(a.z, d.y);
  let span = max(stop - start, 0.0) / params.view.y;
  let wide = across(start, a.z, coil);
  let curling = TAU * coil + wide;
  let share = clamp(curling / max(curling + span - wide, 0.001), 0.1, 0.6);
  var run = u / share * wide;
  if (u >= share) {
    run = wide + (u - share) / (1.0 - share) * (span - wide);
  }
  // The line stands whole from the start; the trails reveal along it.
  let along = start + run * params.view.y;
  let t = select(min(along, params.view.w), along, c.w > 1.5);
  return place(t, swirl((t - start) / params.view.y, wide), coil, b, d.x);
}

@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) a: vec4f,
  @location(1) b: vec4f,
  @location(2) c: vec4f,
  @location(3) d: vec4f,
) -> Ribbon {
  let u = f32(vertex / 2u) / f32(SEGMENTS);
  let side = select(-1.0, 1.0, (vertex & 1u) == 1u);
  let du = 0.5 / f32(SEGMENTS);
  let here = stretch(a, b, c, d, u);
  let ahead = stretch(a, b, c, d, min(u + du, 1.0));
  let behind = stretch(a, b, c, d, max(u - du, 0.0));
  var direction = ahead.xy - behind.xy;
  if (length(direction) < 0.0001) {
    direction = vec2f(1.0, 0.0);
  }
  let normal = normalize(vec2f(-direction.y, direction.x));
  let scale = params.size.z;
  let half = c.y * 0.5 * scale * fullness(here.z);
  let reach = half + (1.5 + c.y * 1.5) * scale;

  var ribbon: Ribbon;
  ribbon.position = clip(here.xy + normal * side * reach);
  ribbon.across = side * reach;
  ribbon.half = half;
  ribbon.color = tone(c.x);
  ribbon.strength = c.z * depth(here.z);
  ribbon.glow = mix(0.35, 1.3, here.z * 0.5 + 0.5);
  return ribbon;
}

@fragment fn fs_main(ribbon: Ribbon) -> @location(0) vec4f {
  let scale = params.size.z;
  let distance = abs(ribbon.across);
  let solid = 1.0 - smoothstep(ribbon.half - 0.5, ribbon.half + 0.75, distance);
  let spread = max(distance - ribbon.half, 0.0) / (1.6 * scale);
  let glow = exp(-spread * spread) * params.mood.x * ribbon.glow;
  let alpha = clamp((solid + glow * (1.0 - solid)) * ribbon.strength, 0.0, 1.0);
  return vec4f(ribbon.color * alpha, alpha);
}
`

/**
 * The beads riding the trails, one bright point each where `beads` in
 * trails.ts placed it this frame.
 */
export const beadsWgsl = /* wgsl */ `
${shared}

struct Bead {
  @builtin(position) position: vec4f,
  @location(0) offset: vec2f,
  @location(1) radius: f32,
  @location(2) color: vec3f,
  @location(3) strength: f32,
}

// a: its place in CSS pixels, how near the reader it is, and its width in
// CSS pixels; b: its colour and strength.
@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) a: vec4f,
  @location(1) b: vec4f,
) -> Bead {
  let scale = params.size.z;
  let radius = a.w * 0.5 * scale * fullness(a.z);
  let extent = radius + 8.0 * scale;
  let corner = vec2f(select(-1.0, 1.0, (vertex & 1u) == 1u), select(-1.0, 1.0, (vertex & 2u) == 2u));

  var rider: Bead;
  rider.position = clip(a.xy * scale + corner * extent);
  rider.offset = corner * extent;
  rider.radius = radius;
  rider.color = tone(b.x);
  rider.strength = b.y * depth(a.z);
  return rider;
}

@fragment fn fs_main(rider: Bead) -> @location(0) vec4f {
  let light = shine(rider.offset, rider.radius, 3.0 * params.size.z, params.mood.x * 2.2);
  let alpha = clamp(light * rider.strength, 0.0, 1.0);
  return vec4f(rider.color * alpha, alpha);
}
`

/**
 * Every event's mark, one square of four vertices each: a chat post is a
 * single crisp pixel, anything else a bright bead with a glow at its curl's
 * tip. The point in focus grows and takes a ring; what just arrived
 * leaves the head as it flares and settles onto its trail. The head, last,
 * sits at now.
 */
export const pointsWgsl = /* wgsl */ `
${shared}

struct Mark {
  @builtin(position) position: vec4f,
  // Where in the square, from its middle, in device pixels.
  @location(0) offset: vec2f,
  // The mark's own radius, in device pixels.
  @location(1) radius: f32,
  @location(2) color: vec3f,
  @location(3) strength: f32,
  // 1 for a square pixel, 2 for the head.
  @location(4) form: f32,
  // How far the ring of focus shows, 0..1.
  @location(5) ring: f32,
  // How far the head flares, 0..1.
  @location(6) flare: f32,
}

// a: its time, the seconds on to its trail's next event, the seconds its
// trail takes to turn once and its widest curl; b: its trail's shape; c: its
// width in CSS pixels, its colour, its index and its strength; d: its form.
@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) a: vec4f,
  @location(1) b: vec4f,
  @location(2) c: vec4f,
  @location(3) d: vec4f,
) -> Mark {
  let isHead = d.x > 1.5;
  let pixel = d.x > 0.5 && d.x < 1.5;
  var t = a.x;
  if (isHead) {
    t = params.size.w;
  }
  let scale = params.size.z;
  // Its mark stands at its curl's tip, half a turn on.
  let coil = curl(a.y, a.w);
  let at = place(t + 0.5 * across(t, a.y, coil) * params.view.y, 3.14159265, coil, b, a.z);
  let focused = select(0.0, params.focus.y, params.focus.x >= 0.0 && abs(c.z - params.focus.x) < 0.5);
  let arrived = select(0.0, params.focus.w, !isHead && t >= params.focus.z);
  let flare = select(0.0, params.focus.w, isHead);
  // What just arrived starts at the head and settles onto its trail.
  let here = mix(at.xy, head(), arrived);
  let shown = select(0.0, 1.0, t <= params.view.w || isHead);
  let radius = c.x * 0.5 * scale * fullness(at.z) * (1.0 + 0.9 * focused + 0.8 * arrived + 0.5 * flare);
  let halo = select(select(5.0, 30.0 * (1.0 + flare), isHead), 0.0, pixel);
  let extent = (radius + (halo + 9.0 * max(focused, arrived)) * scale + 1.0) * shown;
  let corner = vec2f(select(-1.0, 1.0, (vertex & 1u) == 1u), select(-1.0, 1.0, (vertex & 2u) == 2u));

  var mark: Mark;
  mark.position = clip(here + corner * extent);
  mark.offset = corner * extent;
  mark.radius = radius;
  mark.color = tone(c.y);
  mark.strength = c.w * mix(depth(at.z), 1.0, max(focused, arrived));
  mark.form = d.x;
  mark.ring = max(focused, arrived);
  mark.flare = flare;
  return mark;
}

@fragment fn fs_main(mark: Mark) -> @location(0) vec4f {
  let scale = params.size.z;
  var core = 0.0;
  if (mark.form > 0.5 && mark.form < 1.5) {
    let edge = max(abs(mark.offset.x), abs(mark.offset.y));
    core = 1.0 - smoothstep(mark.radius - 0.25, mark.radius + 0.25, edge);
  } else if (mark.form > 1.5) {
    core = shine(mark.offset, mark.radius, 10.0 * (1.0 + mark.flare) * scale, params.mood.x * (2.0 + mark.flare));
  } else {
    core = shine(mark.offset, mark.radius, 3.0 * scale, params.mood.x * 1.8);
  }
  let ringAt = abs(length(mark.offset) - (mark.radius + 6.0 * scale));
  let ring = (1.0 - smoothstep(0.6 * scale, 1.4 * scale, ringAt)) * mark.ring;
  let alpha = clamp(max(core * mark.strength, ring * 0.9), 0.0, 1.0);
  return vec4f(mark.color * alpha, alpha);
}
`
