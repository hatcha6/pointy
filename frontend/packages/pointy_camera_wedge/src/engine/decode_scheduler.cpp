#include "engine/decode_scheduler.h"

#include <utility>

#include "vision/transform.h"

namespace pcw {

bool DecodeScheduler::ShouldDecode(TimePoint now) const {
  if (active(now) || !last_decode_) return true;
  return now - *last_decode_ >= options_.idle_interval;
}

DecodeAttempt DecodeScheduler::NextAttempt() {
  const auto attempt = kCycle[next_];
  next_ = (next_ + 1) % kCycle.size();
  return attempt;
}

void DecodeScheduler::OnDecoded(TimePoint now, bool found) {
  last_decode_ = now;
  if (found) active_until_ = now + options_.active_linger;
}

void DecodeScheduler::OnMotion(TimePoint now) {
  active_until_ = now + options_.active_linger;
}

bool MotionDetector::Update(const LumaImage& frame) {
  Thumbnail(frame, kColumns, kRows, current_);
  const bool moved = !previous_.empty() &&
                     MeanAbsoluteDifference(previous_, current_) > kThreshold;
  std::swap(previous_, current_);
  return moved;
}

}  // namespace pcw
