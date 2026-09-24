// Hands the newest camera frame to the decoder, and only the newest.
//
// A decoder that falls behind must skip frames rather than queue them: a
// queue means decoding what the counter looked like a second ago, which is
// exactly the lag a shop reported. Three buffers rotate — the one the camera
// is filling, the latest finished one, and the one being decoded — so the
// camera never waits for the decoder and nothing is allocated per frame once
// the sizes have settled.
#pragma once

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <utility>

#include "vision/luma_image.h"

namespace pcw {

class FrameMailbox {
 public:
  // Fill the camera-side buffer with `fill(LumaImage&) -> bool` and, if it
  // returns true, make it the latest frame. Called on the camera's thread.
  template <typename Fill>
  bool Publish(Fill&& fill) {
    std::lock_guard<std::mutex> producer(producer_mutex_);
    if (!fill(filling_)) return false;
    filling_.captured_at = Clock::now();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      filling_.sequence = ++sequence_;
      std::swap(filling_, latest_);
      has_new_ = true;
    }
    ready_.notify_one();
    return true;
  }

  // Wait until a frame newer than the last one taken arrives, `deadline`
  // passes, or `stop` is set. On success the frame is swapped into `out`
  // (whose old contents are recycled as a buffer).
  bool WaitTake(LumaImage& out, TimePoint deadline,
                const std::atomic<bool>& stop) {
    std::unique_lock<std::mutex> lock(mutex_);
    ready_.wait_until(lock, deadline, [&] {
      return has_new_ || stop.load(std::memory_order_acquire);
    });
    if (!has_new_ || stop.load(std::memory_order_acquire)) return false;
    std::swap(out, latest_);
    has_new_ = false;
    return true;
  }

  // Wake a waiting decoder so it can notice it is being stopped.
  void Wake() {
    { std::lock_guard<std::mutex> lock(mutex_); }
    ready_.notify_all();
  }

 private:
  // Serialises producers. A backend only ever has one frame in flight, so
  // this is never contended; it is here so that is not an assumption.
  std::mutex producer_mutex_;
  LumaImage filling_;

  std::mutex mutex_;
  std::condition_variable ready_;
  LumaImage latest_;
  bool has_new_ = false;
  uint64_t sequence_ = 0;
};

}  // namespace pcw
