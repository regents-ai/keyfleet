/**
 * The Atlas heat: one quad an instance for each bucket of time a project
 * worked in, coloured by how much work it holds along the page's heat scale,
 * over a faint grid of every bucket (`vs_grid`/`fs_grid`, one triangle across
 * the canvas). Time runs along x in hours, from a base hour near the view so
 * the numbers stay small; each row is a project, below the axis band. The
 * cell chosen with the keys or the pointer wears a ring in the page's focus
 * colour. Everything is premultiplied over a clear canvas, so the page shows
 * through.
 */
export const heatWgsl = /* wgsl */ `
struct Params {
  // Width and height in device pixels, device pixels per CSS pixel, and how
  // strongly this layer is drawn, 0..1.
  size: vec4f,
  // The base hour less the camera's hour, CSS pixels per hour, the first
  // row's top and each row's height, in CSS pixels.
  view: vec4f,
  // The grid's bucket in hours, the hour its buckets start from past the
  // base, how many rows there are, and half the canvas's width in CSS pixels.
  grid: vec4f,
  // Nothing is drawn above x, the band of times, in CSS pixels; the grid
  // leaves row y empty, -1 for none.
  frame: vec4f,
  // The chosen cell: its start past the base, its row, and 1 when one is.
  pick: vec4f,
  // An empty bucket's colour and strength, then the scale from little work
  // to the most.
  tone0: vec4f,
  tone1: vec4f,
  tone2: vec4f,
  tone3: vec4f,
  // The chosen cell's ring.
  ring: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

// The space between rows, and between buckets wide enough to show one, in CSS pixels.
const ROW_GAP = 2.0;
const GAP = 1.0;

struct Cell {
  @builtin(position) position: vec4f,
  // Where in the quad, and how big it is, in CSS pixels.
  @location(0) local: vec2f,
  @location(1) extent: vec2f,
  @location(2) heat: f32,
  @location(3) chosen: f32,
}

// cell: the bucket's start in hours past the base, its length in hours, its
// row, and its heat, 0..1.
@vertex fn vs_main(@builtin(vertex_index) vertex: u32, @location(0) cell: vec4f) -> Cell {
  let zoom = params.view.y;
  let wide = cell.y * zoom;
  let gap = select(0.0, GAP, wide > 3.0);
  let extent = vec2f(max(wide - gap, 1.0), params.view.w - ROW_GAP);
  let corner = vec2f(f32(vertex & 1u), f32(vertex >> 1u));
  let origin = vec2f((cell.x + params.view.x) * zoom + params.grid.w, params.view.z + cell.z * params.view.w);
  let at = (origin + corner * extent) * params.size.z;

  var out: Cell;
  out.position = vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
  out.local = corner * extent;
  out.extent = extent;
  out.heat = cell.w;
  out.chosen = params.pick.z * step(abs(cell.x - params.pick.x), 0.01) * step(abs(cell.z - params.pick.y), 0.01);
  return out;
}

fn ramp(heat: f32) -> vec3f {
  if (heat < 0.5) {
    return mix(params.tone1.rgb, params.tone2.rgb, heat * 2.0);
  }
  return mix(params.tone2.rgb, params.tone3.rgb, heat * 2.0 - 1.0);
}

@fragment fn fs_main(cell: Cell) -> @location(0) vec4f {
  if (cell.position.y / params.size.z < params.frame.x) {
    discard;
  }
  var color = ramp(cell.heat);
  let edge = min(min(cell.local.x, cell.extent.x - cell.local.x), min(cell.local.y, cell.extent.y - cell.local.y));
  if (cell.chosen > 0.5 && edge < 2.0) {
    color = params.ring.rgb;
  }
  let alpha = params.size.w;
  return vec4f(color * alpha, alpha);
}

@vertex fn vs_grid(@builtin(vertex_index) vertex: u32) -> @builtin(position) vec4f {
  let corner = vec2f(f32((vertex << 1u) & 2u), f32(vertex & 2u));
  return vec4f(corner * 2.0 - 1.0, 0.0, 1.0);
}

@fragment fn fs_grid(@builtin(position) position: vec4f) -> @location(0) vec4f {
  let css = position.xy / params.size.z;
  let row = (css.y - params.view.z) / params.view.w;
  if (css.y < params.frame.x || row < 0.0 || row >= params.grid.z || floor(row) == params.frame.y) {
    discard;
  }
  if (fract(row) * params.view.w > params.view.w - ROW_GAP) {
    discard;
  }
  let wide = params.grid.x * params.view.y;
  let hours = (css.x - params.grid.w) / params.view.y - params.view.x;
  if (wide > 3.0 && fract((hours - params.grid.y) / params.grid.x) * wide > wide - GAP) {
    discard;
  }
  let alpha = params.tone0.a * params.size.w;
  return vec4f(params.tone0.rgb * alpha, alpha);
}
`
