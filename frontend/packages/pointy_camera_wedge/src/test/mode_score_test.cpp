// The ranking both backends open a camera by (capture/mode_score.h), on the
// trade-offs a counter camera actually faces.
#include "capture/mode_score.h"
#include "test/check.h"

namespace {

using pcw::ModeCandidate;
using pcw::ModeEncoding;

double Score(int width, int height, double fps,
             ModeEncoding encoding = ModeEncoding::kRaw) {
  return pcw::ScoreMode({width, height, fps, encoding}, 1280, 720);
}

PCW_TEST(the_preferred_size_at_30_fps_uncompressed_is_best) {
  const double best = Score(1280, 720, 30);
  CHECK(best < Score(1280, 720, 15));
  CHECK(best < Score(1280, 720, 30, ModeEncoding::kMjpeg));
  CHECK(best < Score(1920, 1080, 30));
  CHECK(best < Score(640, 480, 30));
}

PCW_TEST(mjpeg_at_720p30_beats_uncompressed_720p_at_10_fps) {
  // USB 2 cannot carry uncompressed 720p at 30 fps: a webcam offers it at
  // 10 or less, and MJPEG at full rate. Agreement needs looks 600 ms apart.
  CHECK(Score(1280, 720, 30, ModeEncoding::kMjpeg) < Score(1280, 720, 10));
}

PCW_TEST(mjpeg_at_720p_beats_uncompressed_vga) {
  // Resolution is what a 1-D barcode lives or dies by.
  CHECK(Score(1280, 720, 30, ModeEncoding::kMjpeg) < Score(640, 480, 30));
}

PCW_TEST(smaller_than_asked_costs_more_than_larger) {
  CHECK(Score(2560, 1440, 30) < Score(640, 360, 30));
  CHECK(Score(1920, 1080, 30) < Score(960, 540, 30));
}

PCW_TEST(faster_than_30_fps_only_breaks_ties) {
  // Same mode at 60: a till copies (and for MJPEG decodes) twice the frames
  // for nothing, since the decoder sets the pace.
  CHECK(Score(1280, 720, 30) < Score(1280, 720, 60));
  CHECK(Score(1280, 720, 30, ModeEncoding::kMjpeg) <
        Score(1280, 720, 60, ModeEncoding::kMjpeg));
  // ...but never outweighs the format or the size.
  CHECK(Score(1280, 720, 60) < Score(1280, 720, 30, ModeEncoding::kMjpeg));
  CHECK(Score(1280, 720, 60) < Score(1920, 1080, 30));
}

PCW_TEST(a_rate_under_15_fps_costs_most_of_all) {
  CHECK(Score(640, 480, 30) < Score(1280, 720, 7.5));
  // A mode that says nothing about its rate ranks as slow.
  CHECK(Score(1280, 720, 15) < Score(1280, 720, 0));
}

PCW_TEST(h264_and_friends_are_a_last_resort) {
  CHECK(Score(640, 480, 30) < Score(1280, 720, 30, ModeEncoding::kOtherCompressed));
}

}  // namespace
