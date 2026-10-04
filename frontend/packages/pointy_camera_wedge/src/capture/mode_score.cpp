#include "capture/mode_score.h"

#include <algorithm>

namespace pcw {

double ScoreMode(const ModeCandidate& mode, int preferred_width,
                 int preferred_height) {
  const double preferred_area =
      static_cast<double>(std::max(1, preferred_width)) * std::max(1, preferred_height);
  const double ratio =
      static_cast<double>(mode.width) * mode.height / preferred_area;
  double score = ratio >= 1 ? (ratio - 1) : (1 / std::max(ratio, 1e-6) - 1) * 2;
  if (mode.fps < 14.5) {
    score += 8 + (15 - mode.fps);
  } else if (mode.fps <= 30.5) {
    score += (30 - std::min(mode.fps, 30.0)) / 30 * 0.6;
  } else {
    // Small enough never to outweigh size or format, only to break a tie.
    score += (std::min(mode.fps, 60.0) - 30) / 30 * 0.1;
  }
  switch (mode.encoding) {
    case ModeEncoding::kRaw:
      // Read as delivered: no decoder, no copy.
      break;
    case ModeEncoding::kMjpeg:
      // Decoding MJPEG costs CPU; worth it only when the camera cannot send
      // the size uncompressed fast enough (USB 2 cannot, at 720p30).
      score += 0.25;
      break;
    case ModeEncoding::kOtherCompressed:
      // Possible, but the decode is heavy for a till.
      score += 5;
      break;
  }
  return score;
}

}  // namespace pcw
