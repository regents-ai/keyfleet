/**
 * The Worldline's two passes over a clear canvas with premultiplied alpha, so
 * the page's own ground shows through: the trails, each a ribbon with a soft
 * glow, then every event's mark on them. Both place a point of a trail by the
 * same sum as `project` in trails.ts: a helix turning around the line, seen a
 * little from above, the side behind the line drawn fainter.
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
  // out, 0..1; the earliest time that just arrived and how bright it still
  // is, 0..1.
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

// A point of a trail at time t, turned theta: where it stands in device
// pixels, and how near the reader it is, -1..1. shape: how far out the trail
// runs, where around the line it starts, how far its turns lean along the
// line, and how fast it turns as the picture orbits.
fn place(t: f32, theta: f32, shape: vec4f) -> vec3f {
  let reach = shape.x * REACH * params.size.y;
  let angle = theta + shape.y + params.view.z * shape.w;
  let s = sin(angle);
  let c = cos(angle);
  let up = reach * c;
  let deep = reach * s * cos(shape.z);
  let x = (t - params.view.x) / params.view.y + reach * s * sin(shape.z);
  let y = params.size.y * 0.5 - (up * cos(ELEVATION) - deep * sin(ELEVATION));
  var near = 0.0;
  if (reach > 0.0) {
    near = (up * sin(ELEVATION) + deep * cos(ELEVATION)) / reach;
  }
  return vec3f(x, y, near);
}

fn clip(at: vec2f) -> vec4f {
  return vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
}

fn depth(near: f32) -> f32 {
  return mix(params.mood.y, 1.0, near * 0.5 + 0.5);
}
`

/**
 * The trails and the line, one ribbon per stretch of trail between two
 * events, or from the last one on into the head at now. The line itself runs
 * from past the left edge to now.
 */
export const trailsWgsl = /* wgsl */ `
${shared}

// Pieces each stretch is cut into; a strip of (SEGMENTS + 1) * 2 vertices.
const SEGMENTS = 40u;

struct Ribbon {
  @builtin(position) position: vec4f,
  // Distance from the middle of the line, in device pixels, either side.
  @location(0) across: f32,
  // Half the solid line's width, in device pixels.
  @location(1) half: f32,
  @location(2) color: vec3f,
  @location(3) strength: f32,
}

// A point u (0..1) of the stretch, held at the latest time revealed yet.
// a: the start's time and turn, the end's time and turn; b: the trail's
// shape; c: its colour, width, strength, and 1 when it runs on to now, 2
// when it is the line itself.
fn stretch(a: vec4f, b: vec4f, c: vec4f, u: f32) -> vec3f {
  var start = a.x;
  var stop = a.z;
  if (c.w > 0.5) {
    stop = params.size.w;
  }
  if (c.w > 1.5) {
    start = params.view.x - params.size.x * params.view.y;
  }
  // The line stands whole from the start; the trails reveal along it.
  let t = select(min(mix(start, stop, u), params.view.w), mix(start, stop, u), c.w > 1.5);
  var k = 0.0;
  if (stop > start) {
    k = clamp((t - start) / (stop - start), 0.0, 1.0);
  }
  // A trail running on from its last event settles into the line at now.
  var form = b;
  if (c.w > 0.5 && c.w < 1.5) {
    form.x = b.x * (1.0 - smoothstep(0.0, 1.0, k));
  }
  return place(t, mix(a.y, a.w, k), form);
}

@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) a: vec4f,
  @location(1) b: vec4f,
  @location(2) c: vec4f,
) -> Ribbon {
  let u = f32(vertex / 2u) / f32(SEGMENTS);
  let side = select(-1.0, 1.0, (vertex & 1u) == 1u);
  let du = 0.5 / f32(SEGMENTS);
  let here = stretch(a, b, c, u);
  let ahead = stretch(a, b, c, min(u + du, 1.0));
  let behind = stretch(a, b, c, max(u - du, 0.0));
  var direction = ahead.xy - behind.xy;
  if (length(direction) < 0.0001) {
    direction = vec2f(1.0, 0.0);
  }
  let normal = normalize(vec2f(-direction.y, direction.x));
  let scale = params.size.z;
  let half = c.y * 0.5 * scale;
  let reach = half + (1.5 + c.y * 1.5) * scale;

  var ribbon: Ribbon;
  ribbon.position = clip(here.xy + normal * side * reach);
  ribbon.across = side * reach;
  ribbon.half = half;
  ribbon.color = tone(c.x);
  ribbon.strength = c.z * depth(here.z);
  return ribbon;
}

@fragment fn fs_main(ribbon: Ribbon) -> @location(0) vec4f {
  let scale = params.size.z;
  let distance = abs(ribbon.across);
  let solid = 1.0 - smoothstep(ribbon.half - 0.5, ribbon.half + 0.75, distance);
  let spread = max(distance - ribbon.half, 0.0) / (1.6 * scale);
  let glow = exp(-spread * spread) * params.mood.x;
  let alpha = clamp((solid + glow * (1.0 - solid)) * ribbon.strength, 0.0, 1.0);
  return vec4f(ribbon.color * alpha, alpha);
}
`

/**
 * Every event's mark, one square of four vertices each: a chat post is a
 * single crisp pixel, anything else a bright point with a glow. The point in
 * focus grows and takes a ring; what just arrived glows brighter for a
 * moment. The line's head sits at now.
 */
export const pointsWgsl = /* wgsl */ `
${shared}

struct Mark {
  @builtin(position) position: vec4f,
  // Where in the square, from its middle, in device pixels.
  @location(0) offset: vec2f,
  // The mark's own radius and how far out it may glow, in device pixels.
  @location(1) radius: f32,
  @location(2) color: vec3f,
  @location(3) strength: f32,
  // 1 for a square pixel, 2 for the head.
  @location(4) form: f32,
  // How far the ring of focus shows, 0..1.
  @location(5) ring: f32,
}

// a: its time and turn, then its trail's reach and start; b: its trail's
// lean and spin, its width in CSS pixels and its colour; c: its index, its
// strength, 1 when it stands at now, and its form.
@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) a: vec4f,
  @location(1) b: vec4f,
  @location(2) c: vec4f,
) -> Mark {
  var t = a.x;
  if (c.z > 0.5) {
    t = params.size.w;
  }
  let here = place(t, a.y, vec4f(a.z, a.w, b.x, b.y));
  let scale = params.size.z;
  let focused = select(0.0, params.focus.y, params.focus.x >= 0.0 && abs(c.x - params.focus.x) < 0.5);
  let arrived = select(0.0, params.focus.w, c.z < 0.5 && t >= params.focus.z);
  let shown = select(0.0, 1.0, t <= params.view.w || c.w > 1.5);
  let radius = b.z * 0.5 * scale * (1.0 + 0.9 * focused + 0.8 * arrived);
  let halo = select(select(4.0, 22.0, c.w > 1.5), 0.0, c.w > 0.5 && c.w < 1.5);
  let extent = (radius + (halo + 9.0 * max(focused, arrived)) * scale + 1.0) * shown;
  let corner = vec2f(select(-1.0, 1.0, (vertex & 1u) == 1u), select(-1.0, 1.0, (vertex & 2u) == 2u));

  var mark: Mark;
  mark.position = clip(here.xy + corner * extent);
  mark.offset = corner * extent;
  mark.radius = radius;
  mark.color = tone(b.w);
  mark.strength = c.y * mix(depth(here.z), 1.0, max(focused, arrived));
  mark.form = c.w;
  mark.ring = max(focused, arrived);
  return mark;
}

@fragment fn fs_main(mark: Mark) -> @location(0) vec4f {
  let scale = params.size.z;
  var core = 0.0;
  if (mark.form > 0.5 && mark.form < 1.5) {
    let edge = max(abs(mark.offset.x), abs(mark.offset.y));
    core = 1.0 - smoothstep(mark.radius - 0.25, mark.radius + 0.25, edge);
  } else {
    let distance = length(mark.offset);
    core = 1.0 - smoothstep(mark.radius - 0.75, mark.radius + 0.75, distance);
    let spread = max(distance - mark.radius, 0.0) / (select(2.5, 9.0, mark.form > 1.5) * scale);
    core = core + exp(-spread * spread) * params.mood.x * 1.6 * (1.0 - core);
  }
  let ringAt = abs(length(mark.offset) - (mark.radius + 6.0 * scale));
  let ring = (1.0 - smoothstep(0.6 * scale, 1.4 * scale, ringAt)) * mark.ring;
  let alpha = clamp(max(core * mark.strength, ring * 0.9), 0.0, 1.0);
  return vec4f(mark.color * alpha, alpha);
}
`
