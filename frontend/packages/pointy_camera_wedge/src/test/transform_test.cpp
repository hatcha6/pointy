#include <cstdint>

#include "test/check.h"
#include "vision/transform.h"

namespace {

pcw::LumaImage Gradient(int w, int h) {
  pcw::LumaImage image;
  image.Resize(w, h);
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x)
      image.row(y)[x] = static_cast<uint8_t>((x * 3 + y * 5) & 0xFF);
  return image;
}

PCW_TEST(rotating_by_zero_is_an_exact_copy) {
  const auto src = Gradient(40, 25);
  pcw::LumaImage dst;
  pcw::RotateScaled(src, 0, 1.0, 255, dst);
  CHECK_EQ(dst.width, 40);
  CHECK_EQ(dst.height, 25);
  CHECK(dst.pixels == src.pixels);
}

PCW_TEST(a_quarter_turn_swaps_the_sides_and_moves_the_corners) {
  const auto src = Gradient(40, 24);
  pcw::LumaImage dst;
  pcw::RotateScaled(src, 90, 1.0, 255, dst);
  // No stray column from cos(90) not quite being zero.
  CHECK_EQ(dst.width, 24);
  CHECK_EQ(dst.height, 40);
  // Clockwise on screen: the source's bottom-left corner ends up top-left,
  // and its top-right ends up bottom-right.
  CHECK_EQ(static_cast<int>(dst.row(0)[0]), static_cast<int>(src.row(23)[0]));
  CHECK_EQ(static_cast<int>(dst.row(39)[23]), static_cast<int>(src.row(0)[39]));
}

PCW_TEST(an_angled_turn_grows_to_the_bounding_box_and_fills_the_corners) {
  const auto src = Gradient(100, 50);
  pcw::LumaImage dst;
  pcw::RotateScaled(src, 30, 1.0, 255, dst);
  // 100*cos30 + 50*sin30 = 111.6; 100*sin30 + 50*cos30 = 93.3.
  CHECK_EQ(dst.width, 112);
  CHECK_EQ(dst.height, 94);
  CHECK_EQ(static_cast<int>(dst.row(0)[0]), 255);
  CHECK_EQ(static_cast<int>(dst.row(93)[111]), 255);
  // The centre stays the centre.
  const int centre = src.row(25)[50];
  const int turned = dst.row(47)[56];
  CHECK(centre - turned <= 8 && turned - centre <= 8);
}

PCW_TEST(scaling_while_rotating_shrinks_the_output) {
  const auto src = Gradient(200, 100);
  pcw::LumaImage dst;
  pcw::RotateScaled(src, 0, 0.5, 255, dst);
  CHECK_EQ(dst.width, 100);
  CHECK_EQ(dst.height, 50);
}

PCW_TEST(downscale_keeps_the_aspect_and_averages) {
  pcw::LumaImage src;
  src.Resize(1280, 720);
  for (int y = 0; y < 720; ++y)
    for (int x = 0; x < 1280; ++x) src.row(y)[x] = (x / 4 + y / 4) % 2 ? 200 : 100;
  pcw::LumaImage dst;
  pcw::Downscale(src, 320, dst);
  CHECK_EQ(dst.width, 320);
  CHECK_EQ(dst.height, 180);
  // Each output pixel covers one 4x4 cell of a single shade.
  CHECK(dst.row(0)[0] == 100 || dst.row(0)[0] == 200);

  pcw::LumaImage small;
  pcw::Downscale(dst, 640, small);  // already small enough: unchanged
  CHECK(small.pixels == dst.pixels);
}

PCW_TEST(thumbnails_notice_a_change_and_ignore_a_repeat) {
  auto a = Gradient(640, 360);
  auto b = a;
  std::vector<uint8_t> ta;
  std::vector<uint8_t> tb;
  pcw::Thumbnail(a, 32, 18, ta);
  pcw::Thumbnail(b, 32, 18, tb);
  CHECK(pcw::MeanAbsoluteDifference(ta, tb) == 0.0);
  // Something dark covering a fifth of the view.
  for (int y = 100; y < 260; ++y)
    for (int x = 200; x < 360; ++x) b.row(y)[x] = 0;
  pcw::Thumbnail(b, 32, 18, tb);
  CHECK(pcw::MeanAbsoluteDifference(ta, tb) > 3.0);
}

// Flat grey with uniform +/- `amplitude` noise from a fixed LCG, so every
// standard library draws the same frame.
pcw::LumaImage NoisyGrey(int w, int h, int grey, int amplitude) {
  pcw::LumaImage image;
  image.Resize(w, h);
  uint32_t state = 12345;
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      state = state * 1664525u + 1013904223u;
      const int offset = static_cast<int>((state >> 16) % (2 * amplitude + 1)) - amplitude;
      image.row(y)[x] = static_cast<uint8_t>(grey + offset);
    }
  return image;
}

PCW_TEST(adaptive_binarize_marks_bars_dark_and_keeps_a_noisy_counter_white) {
  // A dark bar on a grey counter with ordinary sensor noise.
  auto frame = NoisyGrey(320, 120, 150, 8);
  for (int y = 40; y < 80; ++y)
    for (int x = 150; x < 156; ++x) frame.row(y)[x] = 40;
  pcw::LumaImage out;
  std::vector<uint32_t> scratch;
  pcw::AdaptiveBinarize(frame, 16, out, scratch);
  CHECK_EQ(out.width, 320);
  CHECK_EQ(out.height, 120);
  CHECK_EQ(static_cast<int>(out.row(60)[152]), 0);
  // Noise within the margin (10% of the brightness, at least 10 levels)
  // stays white: no specks for the 1-D readers to wade through.
  int specks = 0;
  for (int y = 0; y < 120; ++y)
    for (int x = 0; x < 120; ++x) specks += out.row(y)[x] == 0;
  CHECK_EQ(specks, 0);
}

}  // namespace
