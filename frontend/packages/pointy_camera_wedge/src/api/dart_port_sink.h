// Posts a wedge's events to a Dart port, in the layouts the C ABI header
// documents (include/pointy_camera_wedge.h).
#pragma once

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include "capture/capture_backend.h"
#include "engine/event_sink.h"

namespace pcw {

class DartPortSink final : public EventSink {
 public:
  explicit DartPortSink(int64_t port) : port_(port) {}

  bool OnStatus(const StatusEvent& event) override;
  bool OnScan(const Scan& scan) override;
  bool OnStats(const StatsEvent& stats) override;
  bool OnPreview(const LumaImage& frame) override;

  // The reply to pcw_list_devices.
  bool PostDevices(const std::vector<DeviceInfo>& devices,
                   const CaptureFailure& failure);

  // Whether anyone is still listening. Asks the VM (a bare integer, which the
  // Dart side ignores) unless a post has already failed.
  bool Alive();

 private:
  class Message;
  bool Post(Message& message);

  const int64_t port_;
  std::atomic<bool> alive_{true};
};

}  // namespace pcw
