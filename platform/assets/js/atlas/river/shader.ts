/**
 * The Atlas river: each piece of the stream between two knots is one strip
 * of triangles, an instance each (`vs_band`), its bottom and top worked out
 * from cubic curves through the counts (`./stream` does the same sums on the
 * page). Notebooks wear stripes over a lighter ground, the workspace's work
 * a solid fill, so the two read apart without colour. The chosen band's
 * lanes, one a kind of work, open out of it (`vs_lane`), and inside an hour
 * each thing is a mark along its lane (`vs_mark`): a square for an item of
 * the workspace, a round mark for a notebook. Time runs along x in hours from
 * a base hour near the view, so the numbers stay small; heights are in CSS
 * pixels up from the middle of the stream. Everything is premultiplied over
 * a clear canvas, so the page shows through.
 */
export const riverWgsl = /* wgsl */ `
struct Params {
  // Width and height in device pixels, device pixels per CSS pixel, and how
  // strongly this draw is shown, 0..1.
  size: vec4f,
  // The base hour less the camera's, CSS pixels an hour, half the canvas's
  // width and the middle of the stream, in CSS pixels down from the top.
  view: vec4f,
  // The rest's scale and the chosen band's, in CSS pixels a change, how far
  // the chosen band has opened, and how far its lanes have.
  stack: vec4f,
  // The lanes' region, each lane's height, how far down a lane its line
  // runs, and the lanes' scale, in CSS pixels a change.
  lanes: vec4f,
  // Hours between knots, segments a piece, and the band under the pointer
  // and the chosen band (-1 for none).
  piece: vec4f,
  // How strongly the marks are drawn, how far the cards have come in, the
  // mark or lane under the pointer (-1 for none), and where the stripes start.
  marks: vec4f,
  // Nothing is drawn above x, the times along the top, in CSS pixels; z is
  // how far a mark may sit off its line.
  frame: vec4f,
  tone1: vec4f,
  tone2: vec4f,
  rest: vec4f,
  pick: vec4f,
  mark: vec4f,
  note: vec4f,
  ground: vec4f,
  ring: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

// Half the gap between bands, the stripes' period and width, in CSS pixels.
const GAP = 1.0;
const HATCH = 6.0;
const STRIPE = 1.1;
// The ring around a mark, in CSS pixels.
const RING = 1.5;

const NOTEBOOK = 1u;
const BOTTOM = 2u;
const TOP = 4u;
const REST = 8u;
const ALT = 16u;

fn hermite(c: vec4f, u: f32) -> f32 {
  let u2 = u * u;
  let u3 = u2 * u;
  return (2.0 * u3 - 3.0 * u2 + 1.0) * c.x + (-2.0 * u3 + 3.0 * u2) * c.y + (u3 - 2.0 * u2 + u) * c.z + (u3 - u2) * c.w;
}

fn clip(css: vec2f) -> vec4f {
  let at = css * params.size.z;
  return vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
}

fn screenX(hours: f32) -> f32 {
  return (hours + params.view.x) * params.view.y + params.view.z;
}

// Stripes at 45 degrees, fixed to the stream as it moves: 1 on a stripe.
fn stripe(css: vec2f) -> f32 {
  let along = fract((css.x + css.y + params.marks.w) / HATCH) * HATCH - HATCH * 0.5;
  return 1.0 - smoothstep(STRIPE - 0.6, STRIPE + 0.6, abs(along));
}

fn shade(color: vec3f, notebook: bool, css: vec2f) -> vec3f {
  if (!notebook) {
    return color;
  }
  return mix(mix(color, params.ground.rgb, 0.62), color, stripe(css));
}

struct Band {
  @builtin(position) position: vec4f,
  @location(0) @interpolate(flat) band: f32,
  @location(1) @interpolate(flat) flags: u32,
  @location(2) @interpolate(flat) place: f32,
}

// head: the piece's first knot in hours past the base, its band, its flags
// and where it stands against the chosen band; then the cubics (two counts,
// two slopes) of its own series, of the series below it, of the chosen
// band's series below it, of the whole stack, of the chosen band, and of the
// rest below the chosen band.
@vertex fn vs_band(
  @builtin(vertex_index) vertex: u32,
  @location(0) head: vec4f,
  @location(1) own: vec4f,
  @location(2) below: vec4f,
  @location(3) chosenBelow: vec4f,
  @location(4) total: vec4f,
  @location(5) chosen: vec4f,
  @location(6) otherBelow: vec4f,
) -> Band {
  let u = min(f32(vertex >> 1u) / params.piece.y, 1.0);
  let ko = params.stack.x;
  let kf = params.stack.y;
  let open = params.stack.z;
  let f = max(hermite(chosen, u), 0.0);
  let thick = kf * f;
  let across = mix(thick, params.lanes.x, params.stack.w);
  let t = max(hermite(total, u), 0.0);
  let base = mix(-(ko * (t - f) + across) * 0.5, -across * 0.5 - ko * max(hermite(otherBelow, u), 0.0), open);
  let cb = max(hermite(chosenBelow, u), 0.0);
  var lower = base + ko * (max(hermite(below, u), 0.0) - cb) + kf * cb;
  var weight = ko;
  if (head.w > 1.5) {
    lower += across - thick;
  } else if (head.w > 0.5) {
    lower += (across - thick) * 0.5;
    weight = kf;
  }
  var upper = lower + weight * max(hermite(own, u), 0.0);
  let flags = u32(head.z + 0.5);
  let middle = (lower + upper) * 0.5;
  if ((flags & BOTTOM) != 0u) {
    lower = min(lower + GAP, middle);
  }
  if ((flags & TOP) != 0u) {
    upper = max(upper - GAP, middle);
  }
  let y = select(lower, upper, (vertex & 1u) == 1u);

  var out: Band;
  out.position = clip(vec2f(screenX(head.x + u * params.piece.x), params.view.w - y));
  out.band = head.y;
  out.flags = flags;
  out.place = head.w;
  return out;
}

@fragment fn fs_band(band: Band) -> @location(0) vec4f {
  let css = band.position.xy / params.size.z;
  if (css.y < params.frame.x) {
    discard;
  }
  var color = select(params.tone1.rgb, params.tone2.rgb, (band.flags & ALT) != 0u);
  if ((band.flags & REST) != 0u) {
    color = params.rest.rgb;
  }
  let open = params.stack.z;
  let isChosen = band.place > 0.5 && band.place < 1.5;
  if (isChosen) {
    color = mix(color, params.pick.rgb, 0.3 * open);
  } else if (abs(band.band - params.piece.z) < 0.5) {
    color = mix(color, params.pick.rgb, 0.4);
  }
  color = shade(color, (band.flags & NOTEBOOK) != 0u, css);
  var alpha = params.size.w;
  if (isChosen) {
    // The chosen band gives way to its lanes as soon as they start to open.
    alpha *= 1.0 - smoothstep(0.0, 0.5, params.stack.w);
  } else if (params.piece.w >= 0.0) {
    alpha *= 1.0 - 0.45 * open;
  }
  return vec4f(color * alpha, alpha);
}

struct Lane {
  @builtin(position) position: vec4f,
  @location(0) @interpolate(flat) lane: f32,
  @location(1) @interpolate(flat) notebook: f32,
}

// The middle of lane \`lane\`'s line, up from the middle of the stream.
fn lineOf(lane: f32) -> f32 {
  return params.lanes.x * 0.5 - lane * params.lanes.y - params.lanes.z;
}

// head: the piece's first knot past the base, its lane, and 1 for notebooks;
// then the cubics of its own kind, of the kinds below it in the band, and of
// the whole band.
@vertex fn vs_lane(
  @builtin(vertex_index) vertex: u32,
  @location(0) head: vec4f,
  @location(1) own: vec4f,
  @location(2) below: vec4f,
  @location(3) band: vec4f,
) -> Lane {
  let u = min(f32(vertex >> 1u) / params.piece.y, 1.0);
  let kf = params.stack.y;
  let value = max(hermite(own, u), 0.0);
  let inside = -kf * max(hermite(band, u), 0.0) * 0.5 + kf * max(hermite(below, u), 0.0);
  let line = lineOf(head.y);
  let spread = params.lanes.w * value * 0.5;
  let top = (vertex & 1u) == 1u;
  let inBand = select(inside, inside + kf * value, top);
  let inLane = select(line - spread, line + spread, top);
  let y = mix(inBand, inLane, params.stack.w);

  var out: Lane;
  out.position = clip(vec2f(screenX(head.x + u * params.piece.x), params.view.w - y));
  out.lane = head.y;
  out.notebook = head.z;
  return out;
}

@fragment fn fs_lane(lane: Lane) -> @location(0) vec4f {
  let css = lane.position.xy / params.size.z;
  if (css.y < params.frame.x) {
    discard;
  }
  var color = select(params.tone1.rgb, params.tone2.rgb, (u32(lane.lane + 0.5) & 1u) == 1u);
  if (abs(lane.lane - params.marks.z) < 0.5) {
    color = mix(color, params.pick.rgb, 0.4);
  }
  color = shade(color, lane.notebook > 0.5, css);
  let alpha = params.size.w * smoothstep(0.0, 0.5, params.stack.w) * (1.0 - 0.6 * params.marks.x);
  return vec4f(color * alpha, alpha);
}

struct Mark {
  @builtin(position) position: vec4f,
  @location(0) local: vec2f,
  @location(1) @interpolate(flat) size: f32,
  @location(2) @interpolate(flat) look: vec2f,
  @location(3) @interpolate(flat) chosen: f32,
}

// at: when, past the base, its lane, how far off the line (-0.5..0.5) and
// how big, in CSS pixels; look: 1 for a notebook's round mark, and 1 when
// chosen.
@vertex fn vs_mark(
  @builtin(vertex_index) vertex: u32,
  @builtin(instance_index) index: u32,
  @location(0) at: vec4f,
  @location(1) look: vec4f,
) -> Mark {
  let corner = vec2f(f32(vertex & 1u), f32(vertex >> 1u)) * 2.0 - 1.0;
  let reach = at.w * 0.5 + RING + 1.0;
  let y = lineOf(at.y) + at.z * params.frame.z * (1.0 - params.marks.y);
  let middle = vec2f(screenX(at.x), params.view.w - y);

  var out: Mark;
  out.position = clip(middle + corner * reach);
  out.local = corner * reach;
  out.size = at.w;
  out.look = vec2f(look.x, select(0.0, 1.0, f32(index) == params.marks.z));
  out.chosen = look.y;
  return out;
}

@fragment fn fs_mark(mark: Mark) -> @location(0) vec4f {
  let css = mark.position.xy / params.size.z;
  if (css.y < params.frame.x) {
    discard;
  }
  let radius = mark.size * 0.5;
  let isRound = mark.look.x > 0.5;
  let box = max(abs(mark.local.x), abs(mark.local.y)) - radius;
  let d = select(box, length(mark.local) - radius, isRound);
  var fill = select(params.mark.rgb, params.note.rgb, isRound);
  if (mark.look.y > 0.5) {
    fill = params.pick.rgb;
  }
  let edge = select(params.ground.rgb, params.ring.rgb, mark.chosen > 0.5);
  let inner = clamp(0.5 - d, 0.0, 1.0);
  let outer = clamp(0.5 - (d - RING), 0.0, 1.0);
  let alpha = outer * params.size.w * params.marks.x;
  return vec4f(mix(edge, fill, inner) * alpha, alpha);
}
`
