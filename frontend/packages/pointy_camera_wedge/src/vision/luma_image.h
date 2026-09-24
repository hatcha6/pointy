// An 8-bit greyscale image the wedge owns: what every camera frame becomes
// before anything looks at it.
#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pcw {

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

struct LumaImage {
  int width = 0;
  int height = 0;
  // Row-major, one byte per pixel, rows packed (stride == width).
  std::vector<uint8_t> pixels;
  // When the camera delivered it. The confirmation policy judges agreement
  // by how far apart two looks at the counter were, not by when a decoder
  // happened to get round to them.
  TimePoint captured_at{};
  // Increments per delivered frame; tells a consumer whether it has already
  // seen this one.
  uint64_t sequence = 0;

  void Resize(int new_width, int new_height) {
    width = new_width;
    height = new_height;
    pixels.resize(static_cast<size_t>(new_width) * new_height);
  }

  bool empty() const { return width <= 0 || height <= 0; }

  uint8_t* row(int y) { return pixels.data() + static_cast<size_t>(y) * width; }
  const uint8_t* row(int y) const {
    return pixels.data() + static_cast<size_t>(y) * width;
  }
};

}  // namespace pcw
