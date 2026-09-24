// What a running wedge reports, and to whom.
//
// The engine knows nothing about Dart: the library's C ABI plugs in a sink
// that posts to a Dart port (api/dart_port_sink.h), the tests plug in one that
// records, and the probe tool one that prints.
#pragma once

#include <chrono>
#include <cstdint>

#include "capture/capture_backend.h"
#include "policy/confirmation_policy.h"
#include "vision/luma_image.h"

namespace pcw {

// The PCW_STATE_* values of the C ABI.
enum class WedgeState : int32_t {
  kStarting = 1,
  kRunning = 2,
  kRecovering = 3,
  kStopped = 4,
};

struct StatusEvent {
  WedgeState state = WedgeState::kStarting;
  CaptureFailure failure;
  // What the camera is delivering, when one is (or was just) open.
  StreamInfo stream;
  // When recovering: how long until the next attempt.
  std::chrono::milliseconds retry_in{0};
};

struct StatsEvent {
  uint64_t frames_captured = 0;
  uint64_t frames_decoded = 0;
  uint64_t decode_hits = 0;
  uint64_t scans = 0;
  uint64_t rejected_disagreements = 0;
  uint64_t suppressed_rereads = 0;
  // Frames per second the camera delivered over the last interval.
  double capture_fps = 0;
  // Average time one decode pass took over the last interval.
  double decode_ms_average = 0;
  // Decoding every frame (something moved or was read recently) rather than
  // idling at the floor rate.
  bool active = false;
};

class EventSink {
 public:
  virtual ~EventSink() = default;
  // Each returns false when nobody is listening any more — the app exited or
  // restarted without stopping the wedge — and the engine then stops itself
  // and releases the camera.
  virtual bool OnStatus(const StatusEvent& event) = 0;
  virtual bool OnScan(const Scan& scan) = 0;
  virtual bool OnStats(const StatsEvent& stats) = 0;
  virtual bool OnPreview(const LumaImage& frame) = 0;
};

}  // namespace pcw
