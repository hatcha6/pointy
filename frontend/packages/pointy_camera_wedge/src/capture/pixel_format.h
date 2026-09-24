// The frame layouts a backend may hand over.
//
// A barcode decoder only needs luminance, and every format here carries it in
// a form that is cheap to pull out: planar YUV keeps it as its own plane,
// packed YUV interleaves it with chroma, and RGB needs one weighted sum per
// pixel. Anything compressed (MJPEG, H.264) is decoded by the platform before
// it gets here — the backend asks the OS for one of these.
#pragma once

#include <cstddef>
#include <cstdint>

namespace pcw {

enum class PixelFormat {
  kUnknown,
  kGray8,  // one byte of luminance per pixel (L8, Y800, GREY)
  kNV12,   // Y plane, then interleaved UV at half resolution
  kI420,   // Y plane, then U, then V (IYUV)
  kYV12,   // Y plane, then V, then U
  kYUY2,   // Y0 U Y1 V, two bytes per pixel (YUYV)
  kUYVY,   // U Y0 V Y1, two bytes per pixel
  kRGB24,  // B G R in memory, three bytes per pixel
  kRGB32,  // B G R X in memory, four bytes per pixel
};

// Short name for logs and the settings page.
const char* PixelFormatName(PixelFormat format);

// One frame as the backend holds it, borrowed for the duration of a
// FrameSink::OnFrame call.
struct PixelBuffer {
  PixelFormat format = PixelFormat::kUnknown;
  int width = 0;
  int height = 0;
  // First byte of the TOP row of the first plane, in display order.
  const uint8_t* data = nullptr;
  // Bytes from one row of the first plane to the next, in display order.
  // Negative for bottom-up images, which Windows RGB bitmaps are.
  int stride = 0;
};

}  // namespace pcw
