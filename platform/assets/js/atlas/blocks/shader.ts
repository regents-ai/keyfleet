/**
 * The Atlas blocks: one quad an instance for each tile, a project, a kind of
 * work, a thing or the rest of a kind, coloured along the page's scale by
 * how recently it was worked on, with a pixel of the stage around each, so
 * neighbours stand 2 CSS pixels apart. A tile shows only once its parent has
 * grown far enough toward filling the stage, fading in over its parent's own
 * colour, so a tile opening never reads as older than it is. A tile changed
 * today wears a corner in the ink that reads best on it; the rest of a kind
 * is hatched; the chosen tile wears a ring in the page's focus colour.
 * Everything is premultiplied over a clear canvas.
 */
export const blocksWgsl = /* wgsl */ `
struct Params {
  // Width and height in device pixels, and device pixels per CSS pixel.
  size: vec3f,
  // The camera: the point at the middle of the stage, from the layout's
  // base, the zoom, and the chosen tile's number (-1 for none).
  view: vec4f,
  // Children start to show at x of the zoom that fills the stage with their
  // parent, and show fully at y.
  show: vec2f,
  // The scale from the oldest work to the newest, the rest of a kind, the
  // stage around each tile, the page's text and background, which are the
  // two inks, and the ring.
  tone1: vec4f,
  tone2: vec4f,
  tone3: vec4f,
  rest: vec4f,
  ground: vec4f,
  fg: vec4f,
  bg: vec4f,
  ring: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

struct Tile {
  @builtin(position) position: vec4f,
  // Where in the tile, and how big it is, in CSS pixels.
  @location(0) local: vec2f,
  @location(1) extent: vec2f,
  // How recent its work is (-1 for the rest of a kind), how fully it shows,
  // and the stage around it, in CSS pixels.
  @location(2) look: vec3f,
  // Whether it changed today, and whether it is chosen.
  @location(3) marks: vec2f,
}

// rect: x, y, width and height from the layout's base. tile: how recent its
// work is, the zoom that fills the stage with its parent (0 for a project),
// and its number times two, plus one when it changed today.
@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) rect: vec4f,
  @location(1) tile: vec3f,
) -> Tile {
  let zoom = params.view.z;
  let css = params.size.xy / params.size.z;
  var alpha = 1.0;
  if (tile.y > 0.0) {
    alpha = smoothstep(params.show.x, params.show.y, zoom / tile.y);
  }
  let start = (rect.xy - params.view.xy) * zoom + css * 0.5;
  let extent = rect.zw * zoom;
  let gone = alpha < 0.002 || start.x > css.x || start.y > css.y || start.x + extent.x < 0.0 || start.y + extent.y < 0.0;
  let corner = vec2f(f32(vertex & 1u), f32(vertex >> 1u)) * select(1.0, 0.0, gone);
  let at = (start + corner * extent) * params.size.z;

  var out: Tile;
  out.position = vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
  out.local = corner * extent;
  out.extent = extent;
  // A pixel of the stage on each side, once a tile is big enough to spare it.
  out.look = vec3f(tile.x, alpha, select(0.0, 1.0, min(extent.x, extent.y) > 4.0));
  let code = tile.z;
  out.marks = vec2f(code - 2.0 * floor(code / 2.0), select(0.0, 1.0, floor(code / 2.0) == params.view.w));
  return out;
}

fn ramp(value: f32) -> vec3f {
  if (value < 0.5) {
    return mix(params.tone1.rgb, params.tone2.rgb, value * 2.0);
  }
  return mix(params.tone2.rgb, params.tone3.rgb, value * 2.0 - 1.0);
}

fn luminance(color: vec3f) -> f32 {
  let linear = select(pow((color + 0.055) / 1.055, vec3f(2.4)), color / 12.92, color <= vec3f(0.04045));
  return dot(linear, vec3f(0.2126, 0.7152, 0.0722));
}

fn contrast(a: f32, b: f32) -> f32 {
  return (max(a, b) + 0.05) / (min(a, b) + 0.05);
}

// The ink that stands out most on a colour: the page's text or its background.
fn ink(color: vec3f) -> vec3f {
  let on = luminance(color);
  return select(params.fg.rgb, params.bg.rgb, contrast(on, luminance(params.bg.rgb)) > contrast(on, luminance(params.fg.rgb)));
}

@fragment fn fs_main(tile: Tile) -> @location(0) vec4f {
  let rest = tile.look.x < 0.0;
  let own = select(ramp(tile.look.x), params.rest.rgb, rest);
  var color = own;
  if (rest && fract((tile.local.x + tile.local.y) / 8.0) < 0.5) {
    color = mix(color, ink(color), 0.18);
  }
  // Inside the pixel of stage around it.
  let gap = tile.look.z;
  let local = tile.local - gap;
  let extent = tile.extent - 2.0 * gap;
  // Changed today: a corner, top right, in the ink that reads on the tile.
  let mark = min(12.0, 0.4 * min(extent.x, extent.y));
  if (tile.marks.x > 0.5 && mark >= 4.0 && (extent.x - local.x) + local.y < mark) {
    color = ink(own);
  }
  let edge = min(min(local.x, extent.x - local.x), min(local.y, extent.y - local.y));
  if (tile.marks.y > 0.5 && edge < 2.0) {
    color = params.ring.rgb;
  }
  if (edge < 0.0) {
    color = params.ground.rgb;
  }
  let alpha = tile.look.y;
  return vec4f(color * alpha, alpha);
}
`
