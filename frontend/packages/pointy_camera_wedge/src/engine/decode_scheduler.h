// Which pass to run on a frame, and whether to run one at all.
//
// TWO JOBS, both about spending a till's CPU where it buys a scan:
//
// 1. Orientation. Each frame gets ONE cheap pass, cycling
//    0 / 30 / 60 degrees (plus zxing's own 90-degree steps, so every 30
//    degrees is covered) and, every fourth pass, an inverted one. The camera
//    lab measured this against trying every angle on every frame: the same
//    coverage in ~40 ms of wall time at a live stream's rate, with each
//    decode staying a single pass.
//
// 2. Pace. A counter camera looks at nothing nearly all day. Decoding every
//    frame of an empty counter would keep a core busy for as long as the till
//    is open — on a shop's old dual-core that is the till and the local
//    server fighting the camera. So an idle wedge decodes a few frames a
//    second, and goes to every frame the moment anything moves or anything is
//    read, for a few seconds after.
//
//    Motion only ever SPEEDS decoding up; it never stops it. The lab's first
//    two designs used motion as a gate and both failed the same way — an item
//    placed under the camera stops moving the instant it lands, which is
//    exactly when it needs reading — so the idle pace is the floor.
#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <optional>
#include <vector>

#include "vision/barcode_reader.h"
#include "vision/luma_image.h"

namespace pcw {

class DecodeScheduler {
 public:
  struct Options {
    // Floor: how often an idle wedge still looks.
    std::chrono::milliseconds idle_interval{200};
    // How long after motion or a read the wedge keeps decoding every frame.
    std::chrono::milliseconds active_linger{3000};
  };

  DecodeScheduler() : DecodeScheduler(Options{}) {}
  explicit DecodeScheduler(Options options) : options_(options) {}

  // Whether to decode a frame that arrived at `now`.
  bool ShouldDecode(TimePoint now) const;

  // The next pass in the cycle.
  DecodeAttempt NextAttempt();

  // A pass finished; `found` is whether it read anything at all.
  void OnDecoded(TimePoint now, bool found);

  // Something moved in front of the camera.
  void OnMotion(TimePoint now);

  bool active(TimePoint now) const { return now < active_until_; }

  // The full cycle, exposed so tests can prove it covers every orientation.
  static constexpr std::array<DecodeAttempt, 4> kCycle = {{
      {0, false},
      {30, false},
      {60, false},
      {0, true},
  }};

 private:
  Options options_;
  size_t next_ = 0;
  std::optional<TimePoint> last_decode_;
  TimePoint active_until_{};
};

// Notices that the scene changed between two frames: a hand, an item, a
// receipt held up. Frame-to-frame on a 32x18 block-averaged thumbnail, so
// sensor noise averages away and a real change does not.
class MotionDetector {
 public:
  // Returns true when `frame` differs from the previous one enough to be
  // something arriving or leaving.
  bool Update(const LumaImage& frame);

 private:
  static constexpr int kColumns = 32;
  static constexpr int kRows = 18;
  // Mean absolute difference (0-255) between thumbnails. Noise after
  // averaging sits well under 1; a hand covering a fifth of the view is ~8.
  static constexpr double kThreshold = 3.0;

  std::vector<uint8_t> previous_;
  std::vector<uint8_t> current_;
};

}  // namespace pcw
