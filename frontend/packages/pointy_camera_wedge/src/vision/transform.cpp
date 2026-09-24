#include "vision/transform.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace pcw {
namespace {

constexpr double kPi = 3.14159265358979323846;

}  // namespace

void RotateScaled(const LumaImage& src, int degrees, double scale,
                  uint8_t fill, LumaImage& dst) {
  if (src.empty() || scale <= 0) {
    dst.Resize(0, 0);
    return;
  }
  const double radians = degrees * kPi / 180.0;
  const double cos_t = std::cos(radians);
  const double sin_t = std::sin(radians);
  const double scaled_w = src.width * scale;
  const double scaled_h = src.height * scale;
  // The epsilon keeps a right angle from gaining a column: cos(90 deg) is
  // 6e-17 in floating point, not 0, and ceil() would round that up.
  constexpr double kEpsilon = 1e-6;
  const int out_w = std::max(
      1, static_cast<int>(std::ceil(scaled_w * std::abs(cos_t) +
                                    scaled_h * std::abs(sin_t) - kEpsilon)));
  const int out_h = std::max(
      1, static_cast<int>(std::ceil(scaled_w * std::abs(sin_t) +
                                    scaled_h * std::abs(cos_t) - kEpsilon)));
  dst.Resize(out_w, out_h);
  dst.captured_at = src.captured_at;
  dst.sequence = src.sequence;

  // Inverse mapping from each output pixel centre back into the source, in
  // 16.16 fixed point so the inner loop is two adds and a bounds check:
  //   src = R(-theta) * (dst - dst_centre) / scale + src_centre
  constexpr int kShift = 16;
  constexpr double kOne = 1 << kShift;
  const double inv = 1.0 / scale;
  const double src_cx = src.width / 2.0;
  const double src_cy = src.height / 2.0;
  const double dst_cx = out_w / 2.0;
  const double dst_cy = out_h / 2.0;
  const auto step_x_sx = static_cast<int64_t>(std::llround(cos_t * inv * kOne));
  const auto step_x_sy = static_cast<int64_t>(std::llround(-sin_t * inv * kOne));

  for (int y = 0; y < out_h; ++y) {
    const double dy = y + 0.5 - dst_cy;
    const double dx0 = 0.5 - dst_cx;
    // Source coordinates of this row's first pixel centre. The -0.5 turns a
    // centre into the index that nearest-neighbour rounding lands on.
    const double sx0 = (cos_t * dx0 + sin_t * dy) * inv + src_cx - 0.5;
    const double sy0 = (-sin_t * dx0 + cos_t * dy) * inv + src_cy - 0.5;
    auto sx = static_cast<int64_t>(std::llround(sx0 * kOne)) + (1 << (kShift - 1));
    auto sy = static_cast<int64_t>(std::llround(sy0 * kOne)) + (1 << (kShift - 1));
    uint8_t* out = dst.row(y);
    for (int x = 0; x < out_w; ++x) {
      const int64_t ix = sx >> kShift;
      const int64_t iy = sy >> kShift;
      out[x] = (ix >= 0 && iy >= 0 && ix < src.width && iy < src.height)
                   ? src.pixels[static_cast<size_t>(iy) * src.width +
                                static_cast<size_t>(ix)]
                   : fill;
      sx += step_x_sx;
      sy += step_x_sy;
    }
  }
}

void Downscale(const LumaImage& src, int max_edge, LumaImage& dst) {
  if (src.empty() || max_edge <= 0) {
    dst.Resize(0, 0);
    return;
  }
  const int longer = std::max(src.width, src.height);
  if (longer <= max_edge) {
    dst = src;
    return;
  }
  const double factor = static_cast<double>(max_edge) / longer;
  const int out_w = std::max(1, static_cast<int>(std::lround(src.width * factor)));
  const int out_h = std::max(1, static_cast<int>(std::lround(src.height * factor)));
  dst.Resize(out_w, out_h);
  dst.captured_at = src.captured_at;
  dst.sequence = src.sequence;

  // Integer column bounds are the same for every row, so work them out once.
  std::vector<int> x_start(static_cast<size_t>(out_w) + 1);
  for (int x = 0; x <= out_w; ++x) {
    x_start[static_cast<size_t>(x)] =
        std::min(src.width, static_cast<int>(static_cast<int64_t>(x) * src.width / out_w));
  }
  for (int y = 0; y < out_h; ++y) {
    const int y0 = static_cast<int>(static_cast<int64_t>(y) * src.height / out_h);
    const int y1 = std::max(
        y0 + 1, static_cast<int>(static_cast<int64_t>(y + 1) * src.height / out_h));
    uint8_t* out = dst.row(y);
    for (int x = 0; x < out_w; ++x) {
      const int x0 = x_start[static_cast<size_t>(x)];
      const int x1 = std::max(x0 + 1, x_start[static_cast<size_t>(x) + 1]);
      uint32_t sum = 0;
      for (int sy = y0; sy < y1; ++sy) {
        const uint8_t* row = src.row(sy);
        for (int sx = x0; sx < x1; ++sx) sum += row[sx];
      }
      const auto count = static_cast<uint32_t>((y1 - y0) * (x1 - x0));
      out[x] = static_cast<uint8_t>((sum + count / 2) / count);
    }
  }
}

void AdaptiveBinarize(const LumaImage& src, int radius, LumaImage& dst,
                      std::vector<uint32_t>& scratch) {
  if (src.empty()) {
    dst.Resize(0, 0);
    return;
  }
  const int w = src.width;
  const int h = src.height;
  const size_t stride = static_cast<size_t>(w) + 1;
  // Summed-area table, one row and column of zeros in front. 255 * w * h
  // fits in 32 bits for anything up to ~16 megapixels.
  scratch.assign(stride * (static_cast<size_t>(h) + 1), 0);
  for (int y = 0; y < h; ++y) {
    const uint8_t* row = src.row(y);
    uint32_t running = 0;
    uint32_t* above = scratch.data() + static_cast<size_t>(y) * stride;
    uint32_t* here = above + stride;
    for (int x = 0; x < w; ++x) {
      running += row[x];
      here[x + 1] = above[x + 1] + running;
    }
  }

  dst.Resize(w, h);
  dst.captured_at = src.captured_at;
  dst.sequence = src.sequence;
  for (int y = 0; y < h; ++y) {
    const int y0 = std::max(0, y - radius);
    const int y1 = std::min(h, y + radius + 1);
    const uint32_t* top = scratch.data() + static_cast<size_t>(y0) * stride;
    const uint32_t* bottom = scratch.data() + static_cast<size_t>(y1) * stride;
    const uint8_t* in = src.row(y);
    uint8_t* out = dst.row(y);
    for (int x = 0; x < w; ++x) {
      const int x0 = std::max(0, x - radius);
      const int x1 = std::min(w, x + radius + 1);
      const uint32_t sum = bottom[x1] - bottom[x0] - top[x1] + top[x0];
      const auto area = static_cast<uint32_t>((x1 - x0) * (y1 - y0));
      // Dark means darker than the neighbourhood by 10% of its brightness,
      // and never by less than 10 grey levels: sensor noise on a plain
      // surface stays white.
      const uint32_t pixel_times_area = static_cast<uint32_t>(in[x]) * area;
      const uint32_t margin = std::max(sum / 10, 10u * area);
      out[x] = pixel_times_area + margin < sum ? 0 : 255;
    }
  }
}

void Thumbnail(const LumaImage& src, int columns, int rows,
               std::vector<uint8_t>& out) {
  out.assign(static_cast<size_t>(columns) * rows, 0);
  if (src.empty() || columns <= 0 || rows <= 0) return;
  constexpr int kSampleStep = 4;
  for (int by = 0; by < rows; ++by) {
    const int y0 = by * src.height / rows;
    const int y1 = std::max(y0 + 1, (by + 1) * src.height / rows);
    for (int bx = 0; bx < columns; ++bx) {
      const int x0 = bx * src.width / columns;
      const int x1 = std::max(x0 + 1, (bx + 1) * src.width / columns);
      uint32_t sum = 0;
      uint32_t count = 0;
      for (int y = y0; y < y1; y += kSampleStep) {
        const uint8_t* row = src.row(y);
        for (int x = x0; x < x1; x += kSampleStep) {
          sum += row[x];
          ++count;
        }
      }
      out[static_cast<size_t>(by) * columns + bx] =
          static_cast<uint8_t>(count ? sum / count : 0);
    }
  }
}

double MeanAbsoluteDifference(const std::vector<uint8_t>& a,
                              const std::vector<uint8_t>& b) {
  if (a.size() != b.size() || a.empty()) return 0;
  uint64_t total = 0;
  for (size_t i = 0; i < a.size(); ++i) {
    total += static_cast<uint64_t>(std::abs(static_cast<int>(a[i]) - b[i]));
  }
  return static_cast<double>(total) / static_cast<double>(a.size());
}

}  // namespace pcw
