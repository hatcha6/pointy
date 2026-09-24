#include "vision/luma_extract.h"

#include <cstdlib>
#include <cstring>

namespace pcw {
namespace {

// Bytes per pixel of the first plane, which is all luminance extraction reads.
int FirstPlaneBytesPerPixel(PixelFormat format) {
  switch (format) {
    case PixelFormat::kGray8:
    case PixelFormat::kNV12:
    case PixelFormat::kI420:
    case PixelFormat::kYV12:
      return 1;
    case PixelFormat::kYUY2:
    case PixelFormat::kUYVY:
      return 2;
    case PixelFormat::kRGB24:
      return 3;
    case PixelFormat::kRGB32:
      return 4;
    case PixelFormat::kUnknown:
      break;
  }
  return 0;
}

// BT.601 weights in the same fixed point zxing-cpp uses (ImageView.h,
// RGBToLum), so a frame converted here decodes exactly as zxing would have
// converted it itself.
inline uint8_t Luma(unsigned r, unsigned g, unsigned b) {
  return static_cast<uint8_t>((306 * r + 601 * g + 117 * b + 0x200) >> 10);
}

}  // namespace

bool ExtractLuma(const PixelBuffer& frame, LumaImage& out) {
  const int bytes_per_pixel = FirstPlaneBytesPerPixel(frame.format);
  if (bytes_per_pixel == 0 || frame.data == nullptr || frame.width <= 0 ||
      frame.height <= 0 ||
      std::abs(frame.stride) < frame.width * bytes_per_pixel) {
    return false;
  }

  out.Resize(frame.width, frame.height);
  const int width = frame.width;
  for (int y = 0; y < frame.height; ++y) {
    const uint8_t* src = frame.data + static_cast<ptrdiff_t>(y) * frame.stride;
    uint8_t* dst = out.row(y);
    switch (frame.format) {
      case PixelFormat::kGray8:
      case PixelFormat::kNV12:
      case PixelFormat::kI420:
      case PixelFormat::kYV12:
        std::memcpy(dst, src, static_cast<size_t>(width));
        break;
      case PixelFormat::kYUY2:
        for (int x = 0; x < width; ++x) dst[x] = src[2 * x];
        break;
      case PixelFormat::kUYVY:
        for (int x = 0; x < width; ++x) dst[x] = src[2 * x + 1];
        break;
      case PixelFormat::kRGB24:
        for (int x = 0; x < width; ++x) {
          const uint8_t* p = src + 3 * x;
          dst[x] = Luma(p[2], p[1], p[0]);
        }
        break;
      case PixelFormat::kRGB32:
        for (int x = 0; x < width; ++x) {
          const uint8_t* p = src + 4 * x;
          dst[x] = Luma(p[2], p[1], p[0]);
        }
        break;
      case PixelFormat::kUnknown:
        return false;
    }
  }
  return true;
}

}  // namespace pcw
