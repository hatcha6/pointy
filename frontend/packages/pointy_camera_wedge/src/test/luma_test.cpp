// Every frame layout a driver may hand over comes out as the same grey image.
#include <cstdint>
#include <vector>

#include "capture/pixel_format.h"
#include "test/check.h"
#include "vision/luma_extract.h"

namespace {

using pcw::PixelBuffer;
using pcw::PixelFormat;

// The grey value of pixel (x, y) in every test frame.
uint8_t Expected(int x, int y) { return static_cast<uint8_t>((x * 7 + y * 31) & 0xFF); }

constexpr int kW = 37;  // odd, so nothing lines up by accident
constexpr int kH = 11;
constexpr int kPad = 9;

void CheckGrey(const pcw::LumaImage& image) {
  CHECK_EQ(image.width, kW);
  CHECK_EQ(image.height, kH);
  for (int y = 0; y < kH; ++y) {
    for (int x = 0; x < kW; ++x) {
      if (image.row(y)[x] != Expected(x, y)) {
        CHECK_EQ(static_cast<int>(image.row(y)[x]), static_cast<int>(Expected(x, y)));
      }
    }
  }
}

PCW_TEST(planar_formats_copy_the_y_plane_row_by_row) {
  for (const auto format : {PixelFormat::kGray8, PixelFormat::kNV12,
                            PixelFormat::kI420, PixelFormat::kYV12}) {
    const int stride = kW + kPad;
    std::vector<uint8_t> bytes(static_cast<size_t>(stride) * kH * 2, 0xEE);
    for (int y = 0; y < kH; ++y)
      for (int x = 0; x < kW; ++x) bytes[static_cast<size_t>(y) * stride + x] = Expected(x, y);
    PixelBuffer frame{format, kW, kH, bytes.data(), stride};
    pcw::LumaImage out;
    CHECK(pcw::ExtractLuma(frame, out));
    CheckGrey(out);
  }
}

PCW_TEST(packed_yuv_takes_every_other_byte) {
  const int stride = kW * 2 + kPad;
  std::vector<uint8_t> yuy2(static_cast<size_t>(stride) * kH, 0x80);
  std::vector<uint8_t> uyvy(static_cast<size_t>(stride) * kH, 0x80);
  for (int y = 0; y < kH; ++y) {
    for (int x = 0; x < kW; ++x) {
      yuy2[static_cast<size_t>(y) * stride + 2 * x] = Expected(x, y);
      uyvy[static_cast<size_t>(y) * stride + 2 * x + 1] = Expected(x, y);
    }
  }
  pcw::LumaImage out;
  CHECK(pcw::ExtractLuma({PixelFormat::kYUY2, kW, kH, yuy2.data(), stride}, out));
  CheckGrey(out);
  CHECK(pcw::ExtractLuma({PixelFormat::kUYVY, kW, kH, uyvy.data(), stride}, out));
  CheckGrey(out);
}

PCW_TEST(grey_rgb_comes_back_exactly) {
  // R = G = B = v must give v: the weights sum to one exactly, which is what
  // makes an RGB camera's frame decode the same as a YUV camera's.
  const int stride32 = kW * 4 + kPad;
  const int stride24 = kW * 3 + kPad;
  std::vector<uint8_t> rgb32(static_cast<size_t>(stride32) * kH, 0);
  std::vector<uint8_t> rgb24(static_cast<size_t>(stride24) * kH, 0);
  for (int y = 0; y < kH; ++y) {
    for (int x = 0; x < kW; ++x) {
      auto* p32 = &rgb32[static_cast<size_t>(y) * stride32 + 4 * x];
      p32[0] = p32[1] = p32[2] = Expected(x, y);
      auto* p24 = &rgb24[static_cast<size_t>(y) * stride24 + 3 * x];
      p24[0] = p24[1] = p24[2] = Expected(x, y);
    }
  }
  pcw::LumaImage out;
  CHECK(pcw::ExtractLuma({PixelFormat::kRGB32, kW, kH, rgb32.data(), stride32}, out));
  CheckGrey(out);
  CHECK(pcw::ExtractLuma({PixelFormat::kRGB24, kW, kH, rgb24.data(), stride24}, out));
  CheckGrey(out);
}

PCW_TEST(a_bottom_up_frame_is_turned_the_right_way_up) {
  // Windows RGB bitmaps store the bottom row first and report a negative
  // stride; read naively the barcode is upside down (and so, still readable —
  // which is exactly why this would go unnoticed without a test).
  const int stride = kW * 4;
  std::vector<uint8_t> bytes(static_cast<size_t>(stride) * kH, 0);
  for (int y = 0; y < kH; ++y) {
    const int stored = kH - 1 - y;
    for (int x = 0; x < kW; ++x) {
      auto* p = &bytes[static_cast<size_t>(stored) * stride + 4 * x];
      p[0] = p[1] = p[2] = Expected(x, y);
    }
  }
  const uint8_t* top = bytes.data() + static_cast<size_t>(kH - 1) * stride;
  pcw::LumaImage out;
  CHECK(pcw::ExtractLuma({PixelFormat::kRGB32, kW, kH, top, -stride}, out));
  CheckGrey(out);
}

PCW_TEST(nonsense_geometry_is_refused_not_read_out_of_bounds) {
  std::vector<uint8_t> bytes(64, 0);
  pcw::LumaImage out;
  CHECK(!pcw::ExtractLuma({PixelFormat::kUnknown, 4, 4, bytes.data(), 4}, out));
  CHECK(!pcw::ExtractLuma({PixelFormat::kYUY2, 8, 4, bytes.data(), 8}, out));  // stride < 2w
  CHECK(!pcw::ExtractLuma({PixelFormat::kGray8, 0, 4, bytes.data(), 4}, out));
  CHECK(!pcw::ExtractLuma({PixelFormat::kGray8, 4, 4, nullptr, 4}, out));
}

}  // namespace
