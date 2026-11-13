/**
 * The Atlas field: one quad an instance, in one of three shapes the draw
 * names. A glow is a soft round patch of light, for a cluster's kinds at the
 * fleet's scale. A block is a run of hours, solid, with a hairline between
 * hours wide enough to show one. A point is one thing, square for the
 * workspace's items and round for notebooks, so the two differ by more than
 * colour. Each instance is a rectangle in world units from a base point near
 * the view, so the numbers stay small, and a value: its heat from 0 to 1 on
 * the page's scale, plus 2 for a notebook, or below 0 for the faint ground of
 * a kind's hours. Everything is premultiplied over a clear canvas.
 */
export const fieldWgsl = /* wgsl */ `
struct Params {
  // Width and height in device pixels, device pixels per CSS pixel, and how
  // strongly this layer is drawn, 0..1.
  size: vec4f,
  // The base point less the camera's, CSS pixels a world unit, and the shape:
  // 0 a glow, 1 a block, 2 a point.
  view: vec4f,
  // Half the canvas's width and height, in CSS pixels.
  middle: vec4f,
  // The ground's colour and strength, then the scale from a little work to the most.
  ground: vec4f,
  tone1: vec4f,
  tone2: vec4f,
  tone3: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

struct Shape {
  @builtin(position) position: vec4f,
  // Where in the quad, -1..1 across, and how big it is, in CSS pixels.
  @location(0) local: vec2f,
  @location(1) extent: vec2f,
  @location(2) value: f32,
}

// rect: the corner and size in world units past the base; value as above.
@vertex fn vs_main(
  @builtin(vertex_index) vertex: u32,
  @location(0) rect: vec4f,
  @location(1) value: f32,
) -> Shape {
  let zoom = params.view.z;
  let kind = params.view.w;
  var origin = (rect.xy + params.view.xy) * zoom + params.middle.xy;
  var extent = rect.zw * zoom;
  if (kind > 1.5) {
    // A point fills most of its slot, between two pixels and a mark's size, so
    // the card that takes its place covers it.
    let wide = clamp(min(extent.x, extent.y) * 0.62, 2.0, 16.0);
    origin = origin + (extent - vec2f(wide)) * 0.5;
    extent = vec2f(wide);
  } else if (kind > 0.5) {
    // Blocks keep a hairline between hours once an hour is a few pixels wide.
    let gap = select(0.0, 1.0, min(extent.x, extent.y) > 4.0);
    extent = max(extent - vec2f(gap), vec2f(1.0));
  } else {
    // A glow is never smaller than a few pixels, so a quiet kind still shows.
    let wide = max(extent.x, 6.0);
    origin = origin + (extent - vec2f(wide)) * 0.5;
    extent = vec2f(wide);
  }
  let corner = vec2f(f32(vertex & 1u), f32(vertex >> 1u));
  let at = (origin + corner * extent) * params.size.z;

  var out: Shape;
  out.position = vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
  out.local = corner * 2.0 - 1.0;
  out.extent = extent;
  out.value = value;
  return out;
}

fn ramp(heat: f32) -> vec3f {
  if (heat < 0.5) {
    return mix(params.tone1.rgb, params.tone2.rgb, heat * 2.0);
  }
  return mix(params.tone2.rgb, params.tone3.rgb, heat * 2.0 - 1.0);
}

@fragment fn fs_main(shape: Shape) -> @location(0) vec4f {
  var color = params.ground.rgb;
  var alpha = params.ground.a;
  if (shape.value >= 0.0) {
    let notebook = shape.value >= 2.0;
    let heat = clamp(shape.value - select(0.0, 2.0, notebook), 0.0, 1.0);
    color = ramp(heat);
    alpha = 1.0;
    let kind = params.view.w;
    if (kind < 0.5) {
      let reach = dot(shape.local, shape.local);
      alpha = (0.35 + 0.65 * heat) * exp(-reach * 2.6) * (1.0 - smoothstep(0.85, 1.0, reach));
    } else if (kind > 1.5 && notebook) {
      let reach = length(shape.local);
      let soft = 2.0 / max(shape.extent.x, 2.0);
      alpha = 1.0 - smoothstep(1.0 - soft, 1.0, reach);
    }
  }
  let strength = alpha * params.size.w;
  return vec4f(color * strength, strength);
}
`
