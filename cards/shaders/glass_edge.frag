#version 460 core
#include <flutter/runtime_effect.glsl>

// iOS's soft scroll edge: what scrolls under a pinned header is sharp where
// the header ends and grows blurrier, and more of the page's own colour, up
// to the screen's edge. One pass of a Gaussian whose sigma follows the band,
// run as a backdrop filter clipped to the band, so only the band is ever
// blurred.
//
// Two rounds each way (ImageFilter.compose: small across, large across,
// small down, large down). A single wide pass samples every few pixels, and
// sharp content between its taps (text, a chip's edge) came through as
// stripes; the small round smooths that detail away first, so the large
// round's taps land on content already soft at their spacing. Together they
// make the same blur: sigma² = small² + large².

uniform vec2 u_size;      // set by the engine: the backdrop texture's size
uniform vec4 u_band;      // the band in texture pixels: left, top, width, height
uniform float u_sigma;    // sigma at the top edge, in texture pixels
uniform float u_vertical; // 0 horizontal pass, 1 vertical pass
uniform vec4 u_tint;      // premultiplied page colour at the top edge
uniform float u_scale;    // this round's share of the sigma

uniform sampler2D u_texture;

out vec4 frag_color;

// Taps per side; the stride widens with sigma, so the cost stays flat.
const int TAPS = 16;

// 1 on the screen, 0 past its edge. A tap past the edge would read the edge
// row again, and at the top of the screen half the vertical blur would be
// that one row: the content there only smeared sideways, still readable
// under the status bar. Taps past the edge are dropped instead.
float onScreen(vec2 uv) {
  vec2 inside = step(vec2(0.0), uv) * step(uv, vec2(1.0));
  return inside.x * inside.y;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 uv = p / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  // 0 where the band meets the content, 1 at its top edge; eased at both
  // ends, so the blur starts from nothing and is even under the status bar.
  float t = clamp(1.0 - (p.y - u_band.y) / u_band.w, 0.0, 1.0);
  float s = t * t * (3.0 - 2.0 * t);
  float sigma = u_sigma * s * u_scale;

  vec4 color = texture(u_texture, uv);
  if (sigma >= 0.35) {
    vec2 dir = (u_vertical > 0.5 ? vec2(0.0, 1.0) : vec2(1.0, 0.0)) / u_size;
    float stride = max(1.0, 3.0 * sigma / float(TAPS));
    float k = -0.5 / (sigma * sigma);
    vec4 sum = color;
    float weights = 1.0;
    for (int i = 1; i <= TAPS; i++) {
      float x = float(i) * stride;
      float w = exp(x * x * k);
      vec2 ahead = uv + dir * x;
      vec2 behind = uv - dir * x;
      float wa = w * onScreen(ahead);
      float wb = w * onScreen(behind);
      sum += texture(u_texture, ahead) * wa + texture(u_texture, behind) * wb;
      weights += wa + wb;
    }
    color = sum / weights;
  }

  if (u_vertical > 0.5) {
    color = color * (1.0 - u_tint.a * s) + u_tint * s;
  }
  frag_color = color;
}
