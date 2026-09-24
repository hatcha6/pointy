#include "capture/pixel_format.h"

namespace pcw {

const char* PixelFormatName(PixelFormat format) {
  switch (format) {
    case PixelFormat::kGray8:
      return "GRAY8";
    case PixelFormat::kNV12:
      return "NV12";
    case PixelFormat::kI420:
      return "I420";
    case PixelFormat::kYV12:
      return "YV12";
    case PixelFormat::kYUY2:
      return "YUY2";
    case PixelFormat::kUYVY:
      return "UYVY";
    case PixelFormat::kRGB24:
      return "RGB24";
    case PixelFormat::kRGB32:
      return "RGB32";
    case PixelFormat::kUnknown:
      break;
  }
  return "unknown";
}

}  // namespace pcw
