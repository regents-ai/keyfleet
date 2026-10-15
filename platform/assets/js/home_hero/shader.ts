/**
 * The homepage's two shaders, each one fullscreen pass over a clear canvas
 * with premultiplied alpha, so the page's own ground shows through and only the
 * lines and the light are the shader's.
 *
 * The field: pointy-top hex tiles behind the hero and the Club's map, a hairline
 * rim on each, lit near the pointer and around the Key while it is previewed.
 * The foil: a soft light and a band of sheen over the next Key's card that
 * follow the pointer, with a fine hex grain only where the light falls.
 */

// Pointy-top hexagons, one unit between neighbouring centres across a row,
// with a tile centred on the origin. `hex` returns the point's offset from its cell's centre and how far it is
// from that centre toward the nearest edge, which is 0.5 on the edge itself.
const HEX = /* wgsl */ `
fn hex(p: vec2f) -> vec3f {
  let r = vec2f(1.0, 1.7320508);
  let h = r * 0.5;
  let a = p - r * floor(p / r) - h;
  let b = (p - h) - r * floor((p - h) / r) - h;
  let g = select(b, a, dot(a, a) < dot(b, b));
  let q = abs(g);
  return vec3f(g, max(dot(q, vec2f(0.5, 0.8660254)), q.x));
}

fn over(below: vec4f, rgb: vec3f, alpha: f32) -> vec4f {
  return vec4f(rgb * alpha + below.rgb * (1.0 - alpha), alpha + below.a * (1.0 - alpha));
}

fn grain(cell: vec2f) -> f32 {
  return fract(sin(dot(cell, vec2f(12.9898, 78.233))) * 43758.5453);
}`

export const fieldWgsl = /* wgsl */ `
struct Params {
  size: vec4f,
  line: vec4f,
  light: vec4f,
  pointer: vec4f,
  key: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;
${HEX}

@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  // A tile sits on the canvas's centre, so a field cut to a map's width
  // lies under the map's own tiles.
  let cell = params.size.z;
  let p = (uv - 0.5) * params.size.xy / cell;
  let h = hex(p);
  let centre = (p - h.xy) * cell + params.size.xy * 0.5;
  let aa = 1.0 / cell;

  // Each tile is inset from its neighbours by a gap, with a hairline rim.
  let rim = 1.0 - smoothstep(aa * 0.6, aa * 1.6, abs(h.z - 0.44));
  let face = 1.0 - smoothstep(0.44 - aa, 0.44, h.z);

  // The pointer lights the tiles within a few cells of it, tile by tile.
  let toPointer = distance(centre, params.pointer.xy * params.size.xy) / cell;
  let near = (1.0 - smoothstep(0.6, 3.4, toPointer)) * params.pointer.z;

  // While the Key is previewed, the tiles around it take the light.
  let toKey = distance(centre, params.key.xy * params.size.xy) / max(params.key.z, 1.0);
  let lit = (1.0 - smoothstep(0.15, 1.0, toKey)) * params.pointer.w;

  var color = vec4f(0.0);
  color = over(color, params.line.rgb, face * (0.025 + grain(p - h.xy) * 0.035 + near * 0.08));
  color = over(color, params.line.rgb, rim * (0.16 + near * 0.32));
  color = over(color, params.light.rgb, face * lit * (0.10 + grain(p - h.xy) * 0.08) + rim * lit * 0.45);
  return color;
}`

export const foilWgsl = /* wgsl */ `
struct Params {
  size: vec4f,
  light: vec4f,
  pointer: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;
${HEX}

@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let presence = params.pointer.z;
  let aspect = params.size.x / max(params.size.y, 1.0);
  let at = vec2f(uv.x * aspect, uv.y);
  let pointer = vec2f(params.pointer.x * aspect, params.pointer.y);

  // A soft light where the pointer stands, and a band of sheen across the
  // card that slides with it.
  let spot = 1.0 - smoothstep(0.0, 0.55, distance(at, pointer));
  let across = (uv.x - params.pointer.x) * 0.8 + (uv.y - params.pointer.y) * 0.6;
  let band = 1.0 - smoothstep(0.0, 0.16, abs(across));

  // A fine hex grain, only where the light falls on it.
  let h = hex(uv * params.size.xy / 14.0);
  let grid = 1.0 - smoothstep(0.40, 0.47, h.z);

  var color = vec4f(0.0);
  color = over(color, params.light.rgb, (spot * 0.16 + band * 0.10) * presence);
  color = over(color, params.light.rgb, (1.0 - grid) * spot * 0.12 * presence);
  return color;
}`
