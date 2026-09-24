// One camera acting as a barcode wedge: capture, decode, confirm, report.
//
// Two threads of its own:
//
//  * the CAPTURE thread owns the camera. It opens it, watches it, and when it
//    fails — unplugged, taken by another program, a privacy switch flipped,
//    frames simply stopping — it closes it, reports why, waits, and tries
//    again. A camera plugged back in mid-shift starts reading again without
//    anyone touching settings.
//  * the DECODER thread takes the newest frame (FrameMailbox), runs one
//    zxing pass on it (DecodeScheduler), and asks ConfirmationPolicy whether
//    the result is a scan. It runs below normal priority.
//
// Frames themselves arrive on the backend's threads and are only copied to
// grey there. Nothing the wedge does ever runs on the Flutter UI thread.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

#include "capture/capture_backend.h"
#include "engine/decode_scheduler.h"
#include "engine/event_sink.h"
#include "engine/frame_mailbox.h"
#include "policy/confirmation_policy.h"

namespace pcw {

class WedgeEngine final : private FrameSink {
 public:
  struct Options {
    OpenRequest open;
    ConfirmationPolicy::Options policy;
    DecodeScheduler::Options scheduler;
    std::chrono::milliseconds stats_interval{1000};
    // A camera that opens and then sends nothing is not running. Some take a
    // couple of seconds to settle exposure before the first frame.
    std::chrono::milliseconds first_frame_timeout{8000};
    std::chrono::milliseconds frame_gap_timeout{4000};
  };

  WedgeEngine(std::shared_ptr<CaptureBackend> backend,
              std::shared_ptr<EventSink> sink, Options options);
  ~WedgeEngine() override;

  WedgeEngine(const WedgeEngine&) = delete;
  WedgeEngine& operator=(const WedgeEngine&) = delete;

  void Start();

  // Returns at once; kStopped is reported once the camera is released.
  void RequestStop();

  // Wait for both threads. Never call from a sink callback.
  void Join();

  // Preview frames for the app (aiming the camera, the F8 panel): the newest
  // frame, shrunk to `max_edge`, at most every `interval`. `max_edge` <= 0
  // turns them off, which is the default — nothing is copied for anyone
  // while nobody is looking.
  void SetPreview(int max_edge, std::chrono::milliseconds interval);

 private:
  void CaptureLoop();
  void DecoderLoop();

  // Sleeps for `duration` unless a stop arrives first. True when stopping.
  bool WaitForStop(std::chrono::milliseconds duration);
  std::chrono::milliseconds RetryDelay(const CaptureFailure& failure,
                                       int consecutive_failures) const;
  void Report(WedgeState state, const CaptureFailure& failure,
              const StreamInfo& stream, std::chrono::milliseconds retry_in);

  // FrameSink, called on the backend's threads.
  void OnFrame(const PixelBuffer& frame) override;
  void OnStreamFailure(const CaptureFailure& failure) override;

  const std::shared_ptr<CaptureBackend> backend_;
  const std::shared_ptr<EventSink> sink_;
  const Options options_;

  std::thread capture_thread_;
  std::thread decoder_thread_;
  std::atomic<bool> stop_requested_{false};

  FrameMailbox mailbox_;
  std::atomic<uint64_t> frames_captured_{0};
  std::atomic<int64_t> last_frame_ns_{0};
  std::atomic<bool> first_frame_seen_{false};

  // Guards the capture thread's wait: stop, a stream failure, first frame.
  std::mutex supervisor_mutex_;
  std::condition_variable supervisor_wake_;
  std::optional<CaptureFailure> stream_failure_;

  std::atomic<int> preview_max_edge_{0};
  std::atomic<int64_t> preview_interval_ms_{100};
};

}  // namespace pcw
